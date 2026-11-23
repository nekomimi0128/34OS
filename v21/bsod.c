/* 34os-bsod: full-screen stop screen shown when the live boot USB
 * disappears. The screen is fully rendered into a pixmap at startup
 * (while the USB, and its fonts, are still readable); when the boot
 * device node vanishes, the window is mapped and the pixmap blitted,
 * so the screen still appears after the root filesystem is gone.
 *
 * Usage: 34os-bsod /dev/<boot-device-node>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <X11/Xlib.h>
#include <X11/Xft/Xft.h>

static Display *dpy;
static int scr;
static Window root, win;
static Pixmap pix;
static int sw, sh;
static XftFont *font_head, *font_title, *font_body;
static XftColor white;

static XftFont *load_font(const char *spec)
{
    /* Pick the first candidate that actually has Japanese glyphs. */
    static const char *families[] = {
        "BIZ UDGothic", "Noto Sans CJK JP", "VL Gothic", "sans"
    };
    char buf[256];
    for (size_t i = 0; i < sizeof(families) / sizeof(families[0]); i++) {
        snprintf(buf, sizeof(buf), "%s:%s", families[i], spec);
        XftFont *f = XftFontOpenName(dpy, scr, buf);
        if (f && XftCharExists(dpy, f, 0x3042)) /* U+3042 あ */
            return f;
        if (f)
            XftFontClose(dpy, f);
    }
    return XftFontOpenName(dpy, scr, spec);
}

static int draw_line(XftDraw *draw, XftFont *font, int x, int y,
                     const char *utf8)
{
    XftDrawStringUtf8(draw, &white, font, x, y,
                      (const FcChar8 *)utf8, (int)strlen(utf8));
    return y + font->ascent + font->descent + 10;
}

static void render(void)
{
    Visual *vis = DefaultVisual(dpy, scr);
    Colormap cmap = DefaultColormap(dpy, scr);

    /* Black background, filled while the disk is still there.
     * Same visual style as the boot-time Recovery screen:
     * white BIZ UDGothic text, left-aligned, on plain black. */
    GC gc = XCreateGC(dpy, pix, 0, NULL);
    XSetForeground(dpy, gc, BlackPixel(dpy, scr));
    XFillRectangle(dpy, pix, gc, 0, 0, (unsigned)sw, (unsigned)sh);
    XFreeGC(dpy, gc);

    if (!XftColorAllocName(dpy, vis, cmap, "white", &white))
        return;
    XftDraw *draw = XftDrawCreate(dpy, pix, vis, cmap);
    if (!draw)
        return;

    int x = sw * 60 / 1920; /* 60px left margin at 1920 wide */
    int y = sh / 6 + font_head->ascent;
    y = draw_line(draw, font_head, x, y, "停止");
    y += sh / 30;
    y = draw_line(draw, font_title, x, y,
                  "問題が発生したため、34OS を停止しました");
    y += sh / 40;
    y = draw_line(draw, font_body, x, y,
                  "USBメモリとの接続が切れました。");
    y += sh / 40;
    y = draw_line(draw, font_body, x, y,
                  "エラー [USB-REMOVED]: 起動メディアが取り外されました");
    y += sh / 40;
    draw_line(draw, font_body, x, y,
              "USBメモリを差し直してから、電源ボタンで再起動してください。");
    XftDrawDestroy(draw);
}

int main(int argc, char **argv)
{
    if (argc < 2)
        return 0;
    const char *dev = argv[1];
    struct stat st;
    if (stat(dev, &st) != 0)
        return 0; /* no such device at startup: nothing to guard */

    dpy = XOpenDisplay(NULL);
    if (!dpy)
        return 0;
    scr = DefaultScreen(dpy);
    root = RootWindow(dpy, scr);
    sw = DisplayWidth(dpy, scr);
    sh = DisplayHeight(dpy, scr);

    /* Sizes mirror the Recovery screen at 1080p (90/40/27),
     * scaled to the actual display height. */
    char spec[64];
    snprintf(spec, sizeof(spec), "size=%d:weight=bold", sh / 12);
    font_head = load_font(spec);
    snprintf(spec, sizeof(spec), "size=%d:weight=bold", sh / 27);
    font_title = load_font(spec);
    snprintf(spec, sizeof(spec), "size=%d", sh / 40);
    font_body = load_font(spec);
    if (!font_head || !font_title || !font_body)
        return 0;

    XSetWindowAttributes attr;
    attr.override_redirect = True;
    attr.event_mask = ExposureMask;
    win = XCreateWindow(dpy, root, 0, 0, (unsigned)sw, (unsigned)sh, 0,
                        CopyFromParent, InputOutput, CopyFromParent,
                        CWOverrideRedirect | CWEventMask, &attr);
    pix = XCreatePixmap(dpy, root, (unsigned)sw, (unsigned)sh,
                        (unsigned)DefaultDepth(dpy, scr));
    render();
    XSync(dpy, False);

    /* Poll the boot device; the moment it is gone, show the screen. */
    for (;;) {
        if (stat(dev, &st) != 0)
            break;
        usleep(500 * 1000);
    }

    XMapRaised(dpy, win);
    XCopyArea(dpy, pix, win, DefaultGC(dpy, scr), 0, 0,
              (unsigned)sw, (unsigned)sh, 0, 0);
    XGrabKeyboard(dpy, win, True, GrabModeAsync, GrabModeAsync,
                  CurrentTime);
    XGrabPointer(dpy, win, True, 0, GrabModeAsync, GrabModeAsync,
                 win, None, CurrentTime);
    XSync(dpy, False);

    XEvent ev;
    for (;;) {
        XNextEvent(dpy, &ev);
        if (ev.type == Expose)
            XCopyArea(dpy, pix, win, DefaultGC(dpy, scr), 0, 0,
                      (unsigned)sw, (unsigned)sh, 0, 0);
    }
    return 0;
}
