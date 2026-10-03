// AirFeed receiver. Listens for the camera's SRT stream, decodes it and shows it full
// screen on the display that feeds the ATEM.
//
// The part no off-the-shelf player has is the safety gate: a frame is shown only if every
// packet of it arrived and it decoded without complaint. After any damage nothing new is
// shown until the next keyframe. Meanwhile the last good frame is held for -hold ms, then
// the screen goes black.
//
// usage: airfeed [-port 9000] [-latency 120] [-hold 500] [-display N] [-md5]
//   -latency  SRT receive buffer in ms (the camera may ask for more; the larger one wins)
//   -display  1 = first display, 2 = second, ...; 0 = a window.
//             Default: the second display if there is one, otherwise a window.
//   -md5      no window; print "pts md5" for every frame that would be shown (see test.sh)
// Q or closing the window quits.

#include <srt/srt.h> // first: on Windows it has to pull in winsock2.h before anything else
#ifndef _WIN32
#include <arpa/inet.h>
#endif
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <libavcodec/avcodec.h>
#include <libavutil/md5.h>
#include <libavutil/pixdesc.h>

#define TS 188

static int port = 9000, latency_ms = 120, hold_ms = 500, display = -1, md5_mode;

// Receive thread only.
static SRTSOCKET conn = SRT_INVALID_SOCK;
static int pmt_pid, vpid, last_cc;
static enum AVCodecID codec;
static uint8_t *au;       // the frame being assembled from TS packets
static int au_len, au_cap;
static int au_ok;         // 0 while the frame being assembled is known to be broken
static int64_t au_pts;
static AVCodecContext *dec;
static AVPacket *pkt;
static AVFrame *frame;

static int synced;        // gate open: frames are being let through

// Written by the receive thread, read by the main thread for the status line.
static int n_passed, n_withheld, n_losses;

// Mailbox between the threads. It holds one frame, the newest. Frames are never queued,
// so a burst of late frames after a WiFi outage cannot add delay.
static SDL_Mutex *lock;
static AVFrame *latest;
static int fresh;

static void logf_(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

// ---- safety gate -------------------------------------------------------------------

// Close the gate: show nothing more until the next keyframe.
static void desync(void) {
    if (synced && dec) avcodec_flush_buffers(dec);
    synced = 0;
}

// Data went missing: the frame being assembled is broken, and so is everything that
// depends on it.
static void lose(void) {
    if (au_ok || synced) n_losses++;
    au_ok = 0;
    last_cc = -1;
    desync();
}

// True if the frame can be decoded with no earlier frame: H.264 IDR or HEVC IRAP.
// ponytail: a stream that never sends these (intra refresh only) stays black after the
// first loss. Add recovery point handling if a camera app turns out to work that way.
static int is_keyframe(void) {
    for (int i = 0; i + 3 < au_len; i++) {
        if (au[i] || au[i + 1] || au[i + 2] != 1) continue;
        int h264 = au[i + 3] & 0x1f, hevc = (au[i + 3] >> 1) & 0x3f;
        if (codec == AV_CODEC_ID_H264 ? h264 == 5 : hevc >= 16 && hevc <= 21) return 1;
    }
    return 0;
}

static void print_md5(const AVFrame *f) {
    struct AVMD5 *m = av_md5_alloc();
    uint8_t d[16];
    av_md5_init(m);
    for (int p = 0; p < 3; p++) {
        int w = p ? (f->width + 1) / 2 : f->width, h = p ? (f->height + 1) / 2 : f->height;
        for (int y = 0; y < h; y++) av_md5_update(m, f->data[p] + y * f->linesize[p], w);
    }
    av_md5_final(m, d);
    av_free(m);
    printf("%lld ", (long long)f->pts);
    for (int i = 0; i < 16; i++) printf("%02x", d[i]);
    printf("\n");
}

static void show(AVFrame *f) {
    // ponytail: 8 bit 4:2:0 only. 10 bit HEVC needs a conversion step (libswscale).
    if (f->format != AV_PIX_FMT_YUV420P && f->format != AV_PIX_FMT_YUVJ420P) {
        static int warned;
        if (!warned++) logf_("cannot show pixel format %s", av_get_pix_fmt_name(f->format));
        return;
    }
    n_passed++;
    if (md5_mode) {
        print_md5(f);
        return;
    }
    SDL_LockMutex(lock);
    av_frame_unref(latest);
    av_frame_move_ref(latest, f);
    fresh = 1;
    SDL_UnlockMutex(lock);
}

// A whole frame has been assembled. Let it through only if the gate allows.
static void flush_au(void) {
    if (!au_len) return;
    if (au_ok && !synced && is_keyframe()) synced = 1;
    if (!au_ok || !synced) {
        n_withheld++;
        return;
    }
    if (!dec || dec->codec_id != codec) {
        avcodec_free_context(&dec);
        dec = avcodec_alloc_context3(avcodec_find_decoder(codec));
        // Slice threads add no delay. Frame threads would add one frame per thread.
        // ponytail: software decoding. Use D3D11VA if a laptop cannot keep up.
        dec->thread_type = FF_THREAD_SLICE;
        dec->thread_count = 0;
        if (avcodec_open2(dec, NULL, NULL) < 0) {
            logf_("cannot open a decoder for %s", avcodec_get_name(codec));
            avcodec_free_context(&dec);
            synced = 0;
            return;
        }
        logf_("video: %s", avcodec_get_name(codec));
    }
    memset(au + au_len, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    pkt->data = au;
    pkt->size = au_len;
    pkt->pts = au_pts;
    int r = avcodec_send_packet(dec, pkt);
    while (r >= 0 && (r = avcodec_receive_frame(dec, frame)) >= 0) {
        // Third line of defence: the decoder itself reports damage.
        if ((frame->flags & AV_FRAME_FLAG_CORRUPT) || frame->decode_error_flags) {
            r = AVERROR_INVALIDDATA;
            break;
        }
        show(frame);
        av_frame_unref(frame);
    }
    if (r < 0 && r != AVERROR(EAGAIN)) desync();
}

// ---- MPEG-TS -----------------------------------------------------------------------

// Program tables: find the video stream and its codec.
// ponytail: tables longer than one TS packet are ignored (many streams in one program).
static void psi(int pid, const uint8_t *d, int n) {
    if (n < 1 || n < 1 + d[0] + 12) return;
    const uint8_t *s = d + 1 + d[0];
    int end = 3 + (((s[1] & 0x0f) << 8) | s[2]) - 4; // without the CRC
    if (end > n - 1 - d[0]) return;
    if (pid == 0 && s[0] == 0x00) {
        for (int i = 8; i + 4 <= end; i += 4)
            if (s[i] << 8 | s[i + 1]) pmt_pid = ((s[i + 2] & 0x1f) << 8) | s[i + 3];
    } else if (pid == pmt_pid && s[0] == 0x02) {
        int i = 12 + (((s[10] & 0x0f) << 8) | s[11]);
        for (; i + 5 <= end; i += 5 + (((s[i + 3] & 0x0f) << 8) | s[i + 4])) {
            if (s[i] != 0x1b && s[i] != 0x24) continue;
            vpid = ((s[i + 1] & 0x1f) << 8) | s[i + 2];
            codec = s[i] == 0x1b ? AV_CODEC_ID_H264 : AV_CODEC_ID_HEVC;
            return;
        }
    }
}

static void ts_packet(const uint8_t *p) {
    int pid = ((p[1] & 0x1f) << 8) | p[2], start = p[1] & 0x40, afc = (p[3] >> 4) & 3;
    int off = 4 + ((afc & 2) ? 1 + p[4] : 0);
    if (!(afc & 1) || off >= TS) return; // no payload
    const uint8_t *d = p + off;
    int n = TS - off;

    if (pid == 0 || pid == pmt_pid) {
        if (start) psi(pid, d, n);
        return;
    }
    if (pid != vpid) return;

    // Second line of defence: the TS continuity counter catches loss that happened
    // before SRT, inside the camera app.
    int cc = p[3] & 15;
    if (last_cc >= 0 && cc != ((last_cc + 1) & 15)) lose();
    last_cc = cc;

    if (start) {
        // A frame is complete only when the next one starts, which costs one frame of
        // delay. ponytail: finish early when the camera sends a PES length (frames
        // under 64 KB), if the measured latency needs it.
        flush_au();
        au_len = 0;
        au_ok = n >= 9 && d[0] == 0 && d[1] == 0 && d[2] == 1 && 9 + d[8] <= n;
        if (!au_ok) return;
        au_pts = AV_NOPTS_VALUE;
        if ((d[7] & 0x80) && d[8] >= 5)
            au_pts = (int64_t)(d[9] & 0x0e) << 29 | d[10] << 22 | (d[11] & 0xfe) << 14 | d[12] << 7 | d[13] >> 1;
        n -= 9 + d[8];
        d += 9 + d[8];
    }
    if (!au_ok) return;
    if (au_len + n + AV_INPUT_BUFFER_PADDING_SIZE > au_cap) {
        au_cap = 2 * au_cap + (1 << 20);
        au = av_realloc(au, au_cap);
    }
    memcpy(au + au_len, d, n);
    au_len += n;
}

// ---- SRT ---------------------------------------------------------------------------

// One camera connection, from connect to disconnect.
static void stream(void) {
    char msg[1500];
    int32_t next_seq = -1;
    int warned = 0;

    pmt_pid = vpid = last_cc = -1;
    au_len = au_ok = synced = 0;
    for (;;) {
        SRT_MSGCTRL mc = srt_msgctrl_default;
        int n = srt_recvmsg2(conn, msg, sizeof msg, &mc);
        if (n == SRT_ERROR) break;
        // First line of defence: SRT numbers every packet. A jump in the numbers means
        // a packet was lost for good (SRT gave up on getting it resent in time).
        if (next_seq >= 0 && mc.pktseq != next_seq) lose();
        next_seq = (mc.pktseq + 1) & 0x7fffffff; // the numbers wrap at 31 bits
        // ponytail: assumes every SRT packet holds whole TS packets. A camera app that
        // splits them differently gets a black screen and this message.
        if (n % TS || msg[0] != 0x47) {
            if (!warned++) logf_("stream is not MPEG-TS in whole packets, cannot show it");
            lose();
            continue;
        }
        for (int i = 0; i < n; i += TS) ts_packet((const uint8_t *)msg + i);
    }
    desync();
}

static int receive(void *arg) {
    SRTSOCKET listener = srt_create_socket();
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = INADDR_ANY;
    srt_setsockflag(listener, SRTO_RCVLATENCY, &latency_ms, sizeof latency_ms);
    if (srt_bind(listener, (struct sockaddr *)&sa, sizeof sa) == SRT_ERROR || srt_listen(listener, 1) == SRT_ERROR) {
        logf_("cannot listen on UDP port %d: %s", port, srt_getlasterror_str());
        exit(1);
    }
    pkt = av_packet_alloc();
    frame = av_frame_alloc();
    for (;;) {
        logf_("waiting for the camera on UDP port %d", port);
        SRTSOCKET s = srt_accept(listener, NULL, NULL);
        if (s == SRT_INVALID_SOCK) continue;
        int ms = 0, len = sizeof ms;
        srt_getsockflag(s, SRTO_RCVLATENCY, &ms, &len);
        logf_("camera connected, SRT buffer %d ms", ms);
        conn = s;
        stream();
        conn = SRT_INVALID_SOCK;
        srt_close(s);
        logf_("camera disconnected: %d frames passed, %d withheld, %d losses", n_passed, n_withheld, n_losses);
        if (md5_mode) {
            srt_close(listener);
            return 0;
        }
    }
}

// ---- display -----------------------------------------------------------------------

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        int *v = !strcmp(argv[i], "-port") ? &port : !strcmp(argv[i], "-latency") ? &latency_ms :
                 !strcmp(argv[i], "-hold") ? &hold_ms : !strcmp(argv[i], "-display") ? &display : NULL;
        if (v && i + 1 < argc) *v = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-md5")) md5_mode = 1;
        else {
            logf_("usage: airfeed [-port 9000] [-latency 120] [-hold 500] [-display N] [-md5]");
            return 2;
        }
    }
    srt_startup();
    if (md5_mode) return receive(NULL);

    if (!SDL_Init(SDL_INIT_VIDEO)) {
        logf_("SDL: %s", SDL_GetError());
        return 1;
    }
    int n_displays = 0;
    SDL_DisplayID *ids = SDL_GetDisplays(&n_displays);
    for (int i = 0; i < n_displays; i++) {
        SDL_Rect r = {0};
        SDL_GetDisplayBounds(ids[i], &r);
        logf_("display %d: %s, %d x %d", i + 1, SDL_GetDisplayName(ids[i]), r.w, r.h);
    }
    if (display < 0) display = n_displays > 1 ? 2 : 0;
    if (display > n_displays) {
        logf_("there is no display %d, only %d", display, n_displays);
        return 1;
    }
    SDL_PropertiesID wp = SDL_CreateProperties();
    SDL_SetStringProperty(wp, SDL_PROP_WINDOW_CREATE_TITLE_STRING, "AirFeed");
    SDL_SetNumberProperty(wp, SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, 1280);
    SDL_SetNumberProperty(wp, SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, 720);
    SDL_SetBooleanProperty(wp, SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true);
    if (display) {
        SDL_SetNumberProperty(wp, SDL_PROP_WINDOW_CREATE_X_NUMBER, SDL_WINDOWPOS_CENTERED_DISPLAY(ids[display - 1]));
        SDL_SetNumberProperty(wp, SDL_PROP_WINDOW_CREATE_Y_NUMBER, SDL_WINDOWPOS_CENTERED_DISPLAY(ids[display - 1]));
        SDL_SetBooleanProperty(wp, SDL_PROP_WINDOW_CREATE_FULLSCREEN_BOOLEAN, true);
    }
    SDL_Window *win = SDL_CreateWindowWithProperties(wp);
    SDL_Renderer *ren = win ? SDL_CreateRenderer(win, NULL) : NULL;
    if (!ren) {
        logf_("SDL: %s", SDL_GetError());
        return 1;
    }
    // Vsync: without it the ATEM would see torn frames.
    int vsync = SDL_SetRenderVSync(ren, 1);
    if (display) SDL_HideCursor();
    SDL_DisableScreenSaver(); // also keeps the display from sleeping
    SDL_RaiseWindow(win);
    if (display) logf_("output: full screen on display %d, renderer %s%s", display, SDL_GetRendererName(ren), vsync ? "" : ", NO VSYNC");
    else logf_("output: a window on this screen, renderer %s%s", SDL_GetRendererName(ren), vsync ? "" : ", NO VSYNC");

    lock = SDL_CreateMutex();
    latest = av_frame_alloc();
    AVFrame *f = av_frame_alloc();
    SDL_CreateThread(receive, "receive", NULL);

    SDL_Texture *tex = NULL;
    int tw = 0, th = 0, shown = 0;
    SDL_Colorspace tcs = 0;
    Uint64 last_frame = 0, last_stats = SDL_GetTicks();
    for (;;) {
        SDL_Event e;
        while (SDL_PollEvent(&e))
            if (e.type == SDL_EVENT_QUIT || (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_Q)) {
                SDL_Quit();
                exit(0); // ponytail: the receive thread is not shut down, the process just ends
            }

        SDL_LockMutex(lock);
        int got = fresh;
        if (got) av_frame_move_ref(f, latest);
        fresh = 0;
        SDL_UnlockMutex(lock);

        if (got) {
            int full = f->color_range == AVCOL_RANGE_JPEG || f->format == AV_PIX_FMT_YUVJ420P;
            int bt601 = f->colorspace == AVCOL_SPC_BT470BG || f->colorspace == AVCOL_SPC_SMPTE170M ||
                        (f->colorspace == AVCOL_SPC_UNSPECIFIED && f->height < 720);
            SDL_Colorspace cs = bt601 ? (full ? SDL_COLORSPACE_BT601_FULL : SDL_COLORSPACE_BT601_LIMITED)
                                      : (full ? SDL_COLORSPACE_BT709_FULL : SDL_COLORSPACE_BT709_LIMITED);
            if (!tex || tw != f->width || th != f->height || tcs != cs) {
                if (tex) SDL_DestroyTexture(tex);
                SDL_PropertiesID tp = SDL_CreateProperties();
                SDL_SetNumberProperty(tp, SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER, SDL_PIXELFORMAT_IYUV);
                SDL_SetNumberProperty(tp, SDL_PROP_TEXTURE_CREATE_ACCESS_NUMBER, SDL_TEXTUREACCESS_STREAMING);
                SDL_SetNumberProperty(tp, SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER, tw = f->width);
                SDL_SetNumberProperty(tp, SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER, th = f->height);
                SDL_SetNumberProperty(tp, SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER, tcs = cs);
                tex = SDL_CreateTextureWithProperties(ren, tp);
                SDL_DestroyProperties(tp);
                SDL_SetRenderLogicalPresentation(ren, tw, th, SDL_LOGICAL_PRESENTATION_LETTERBOX);
                logf_("picture: %d x %d, %s %s range", tw, th, bt601 ? "BT.601" : "BT.709", full ? "full" : "limited");
            }
            if (tex && SDL_UpdateYUVTexture(tex, NULL, f->data[0], f->linesize[0], f->data[1], f->linesize[1],
                                            f->data[2], f->linesize[2])) {
                last_frame = SDL_GetTicks();
                shown++;
            }
            av_frame_unref(f);
        }

        // Hold the last good frame for a moment, then black.
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        SDL_RenderClear(ren);
        int on_air = tex && last_frame && SDL_GetTicks() - last_frame <= (Uint64)hold_ms;
        if (on_air) SDL_RenderTexture(ren, tex, NULL, NULL);
        SDL_RenderPresent(ren);
        if (!vsync) SDL_Delay(2);

        if (SDL_GetTicks() - last_stats >= 1000) {
            SRT_TRACEBSTATS s;
            if (conn != SRT_INVALID_SOCK && srt_bstats(conn, &s, 0) != SRT_ERROR)
                logf_("%s %3d shown/s | passed %d, withheld %d, losses %d | SRT: rtt %.0f ms, lost on WiFi %d, not recovered %d, buffer %d ms",
                      on_air ? "LIVE " : "BLACK", shown, n_passed, n_withheld, n_losses, s.msRTT, s.pktRcvLossTotal,
                      s.pktRcvDropTotal, s.msRcvBuf);
            shown = 0;
            last_stats = SDL_GetTicks();
        }
    }
}
