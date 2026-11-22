/*
 * 34os-wm - the 34OS v2.1 window manager + panel (single-file X11 program)
 *
 * A small reparenting window manager with a built-in bottom panel:
 * start button + start menu, task buttons, simple indicators and a
 * JST clock. Written against Xlib + Xft only (PNG wallpaper loading
 * uses Imlib2 when built with HAVE_IMLIB2, plain colour otherwise).
 *
 * Design rules (fixed by the 34OS spec):
 *   - flat, dark charcoal + white line art. No rounded corners,
 *     no gradients, no shadows.
 *   - one workspace, one bottom panel, start button at bottom-left.
 *   - generic enough for apps installed later via apt: basic EWMH
 *     (_NET_SUPPORTED, _NET_WM_NAME, _NET_WM_STATE_FULLSCREEN,
 *     dialogs centred over their parent) is honoured.
 */

#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/Xft/Xft.h>

#include <dirent.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef HAVE_IMLIB2
#include <Imlib2.h>
#endif

/* ------------------------------------------------------------------ */
/* Tunables                                                            */
/* ------------------------------------------------------------------ */

#define PANEL_H        40   /* bottom panel height in px              */
#define TITLE_H        28   /* frame title bar height in px           */
#define BORDER_W       1    /* frame border width in px               */
#define GRIP           18   /* bottom-right resize grip size in px    */
#define MIN_W          140  /* minimum client width                   */
#define MIN_H          90   /* minimum client height                  */
#define MENU_W         228  /* start menu width in px                 */
#define MENU_ITEM_H    31   /* start menu item height in px           */
#define TASKBTN_MAXW   184  /* maximum task button width in px        */
#define STARTBTN_W     92   /* start button width in px               */

#define WALLPAPER_DIR  "/usr/share/34os/wallpapers"
#define WALLPAPER_DEFAULT WALLPAPER_DIR "/steam-locomotive.png"

/* Flat palette: charcoal tones + white line art only. */
#define COL_PANEL_BG   "#262626"
#define COL_PANEL_LINE "#4a4a4a"
#define COL_TITLE_ON   "#383838"  /* focused title bar   */
#define COL_TITLE_OFF  "#232323"  /* unfocused title bar */
#define COL_FRAME_LINE "#5a5a5a"
#define COL_MENU_BG    "#2b2b2b"
#define COL_MENU_HOVER "#3d3d3d"
#define COL_TASK_ON    "#3d3d3d"
#define COL_TASK_OFF   "#2b2b2b"
#define COL_TEXT       "#ececec"
#define COL_TEXT_DIM   "#9a9a9a"
#define COL_DESKTOP    "#1d1d1d"  /* fallback desktop colour */

/* ------------------------------------------------------------------ */
/* Types                                                               */
/* ------------------------------------------------------------------ */

typedef struct Client {
    Window win;          /* the application's window              */
    Window frame;        /* our frame window (title bar + border) */
    int x, y;            /* frame position (root coordinates)     */
    int w, h;            /* client size (frame is bigger)         */
    int saved_x, saved_y, saved_w, saved_h; /* pre-maximise/fullscreen */
    int min_w, min_h;    /* from WM_NORMAL_HINTS, 0 = unset       */
    Bool iconic;         /* minimised                             */
    Bool maximized;
    Bool fullscreen;
    Bool is_dialog;
    char *title;         /* owned copy of the window title        */
    struct Client *next;
} Client;

/* Start menu actions. Placeholder actions are kept as separate
 * functions below so the unfinished behaviour is easy to find. */
enum Action {
    ACT_NONE = 0,
    ACT_BROWSER, ACT_FILES, ACT_TERMINAL, ACT_WRITER, ACT_CALC,
    ACT_SUB_WALLPAPER, ACT_WALLPAPER_DIR,
    ACT_WP_LOCO, ACT_WP_MOON, ACT_WP_LIGHT,
    ACT_SUB_KYOKAN, ACT_HOTSPOT_ON, ACT_HOTSPOT_OFF,
    ACT_WORKSPACES, ACT_SETTINGS,
    ACT_TO_CLI, ACT_REBOOT, ACT_POWEROFF
};

typedef struct {
    const char *label;
    enum Action action;
    Bool has_submenu;
} MenuItem;

/* ------------------------------------------------------------------ */
/* Globals                                                             */
/* ------------------------------------------------------------------ */

static Display *dpy;
static int scr;
static Window root;
static int sw, sh;                 /* screen size                  */

static XftFont *font;              /* regular UI font              */
static XftFont *font_big;          /* start button / clock         */
static XftColor col_text, col_dim;
static unsigned long px_panel_bg, px_panel_line, px_title_on,
    px_title_off, px_frame_line, px_menu_bg, px_menu_hover,
    px_task_on, px_task_off, px_desktop;

static Window panel;               /* our panel window             */
static Window menu_win;            /* start menu window (0=closed) */
static Window submenu_win;         /* submenu window (0=closed)    */
static int menu_hover = -1;        /* hovered main-menu index      */
static int submenu_hover = -1;     /* hovered submenu index        */
static int submenu_parent = -1;    /* main-menu index owning submenu */

static Client *clients = NULL;     /* managed windows              */
static Client *focused = NULL;

static Bool running = True;

/* Drag state (move / resize), all in root coordinates. */
static struct {
    Client *c;
    int mode;                      /* 0 none, 1 move, 2 resize     */
    int start_x, start_y;
    int orig_x, orig_y, orig_w, orig_h;
} drag = { NULL, 0, 0, 0, 0, 0, 0, 0 };

/* Atoms */
static Atom xa_wm_protocols, xa_wm_delete, xa_wm_state, xa_wm_transient;
static Atom xa_net_supported, xa_net_client_list, xa_net_active_window,
    xa_net_wm_name, xa_net_wm_state, xa_net_wm_state_fullscreen,
    xa_net_wm_state_max_horz, xa_net_wm_state_max_vert,
    xa_net_wm_window_type, xa_net_wm_window_type_dialog,
    xa_net_wm_window_type_dock, xa_net_close_window,
    xa_net_number_of_desktops, xa_net_current_desktop, xa_net_wm_desktop,
    xa_net_frame_extents, xa_net_wm_strut_partial, xa_xrootpmap_id;

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

/* Ignore X errors: a client can vanish at any time and racing it
 * must never take the WM down. Errors are logged to stderr only. */
static int xerror(Display *d, XErrorEvent *e)
{
    char buf[128];
    XGetErrorText(d, e->error_code, buf, sizeof buf);
    fprintf(stderr, "34os-wm: X error (ignored): %s\n", buf);
    return 0;
}

static unsigned long color_pixel(const char *hex)
{
    XColor c;
    Colormap cm = DefaultColormap(dpy, scr);
    if (!XParseColor(dpy, cm, hex, &c) || !XAllocColor(dpy, cm, &c))
        return BlackPixel(dpy, scr);
    return c.pixel;
}

static void xft_color(const char *hex, XftColor *out)
{
    XftColorAllocName(dpy, DefaultVisual(dpy, scr),
                      DefaultColormap(dpy, scr), hex, out);
}

/* Pixel width of a UTF-8 string in the given font. */
static int text_w(XftFont *f, const char *s)
{
    XGlyphInfo ext;
    if (!s) return 0;
    XftTextExtentsUtf8(dpy, f, (const FcChar8 *)s, strlen(s), &ext);
    return ext.xOff;
}

/* Draw UTF-8 text; (x, y) is the baseline origin. Caller frees draw. */
static void draw_text(Drawable d, XftFont *f, const XftColor *col,
                      int x, int y, const char *s)
{
    XftDraw *draw;
    if (!s) return;
    draw = XftDrawCreate(dpy, d, DefaultVisual(dpy, scr),
                         DefaultColormap(dpy, scr));
    XftDrawStringUtf8(draw, col, f, x, y, (const FcChar8 *)s, strlen(s));
    XftDrawDestroy(draw);
}

/* Draw text clipped to maxw px, appending nothing (hard clip). */
static void draw_text_clip(Drawable d, XftFont *f, const XftColor *col,
                           int x, int y, int maxw, const char *s)
{
    /* Cheap clip: shorten the string until it fits. Titles are
     * short in practice; a byte-wise walk that respects UTF-8
     * continuation bytes is good enough here. */
    char buf[256];
    size_t len;
    if (!s) return;
    snprintf(buf, sizeof buf, "%s", s);
    len = strlen(buf);
    while (len > 0 && text_w(f, buf) > maxw) {
        len--;
        while (len > 0 && (buf[len] & 0xC0) == 0x80) len--;
        buf[len] = '\0';
    }
    draw_text(d, f, col, x, y, buf);
}

/* Launch a program detached from the WM (double-fork, no zombie). */
static void spawn(const char *const argv[])
{
    pid_t pid = fork();
    if (pid == 0) {
        if (fork() == 0) {
            setsid();
            execvp(argv[0], (char *const *)argv);
            _exit(127);
        }
        _exit(0);
    }
    if (pid > 0) waitpid(pid, NULL, 0);
}

/* Read a small text file fully; returns malloc'd string or NULL. */
static char *read_small_file(const char *path)
{
    FILE *fp = fopen(path, "r");
    char buf[128];
    if (!fp) return NULL;
    if (!fgets(buf, sizeof buf, fp)) { fclose(fp); return NULL; }
    fclose(fp);
    buf[strcspn(buf, "\n")] = '\0';
    return strdup(buf);
}

/* ------------------------------------------------------------------ */
/* Indicators (polled from /sys and amixer; text + line art level)     */
/* ------------------------------------------------------------------ */

/* Battery charge 0-100, or -1 when there is no battery (desktop/AC). */
static int read_battery(void)
{
    DIR *dir = opendir("/sys/class/power_supply");
    struct dirent *de;
    int result = -1;
    if (!dir) return -1;
    while ((de = readdir(dir)) != NULL) {
        char path[512], *type, *cap;
        snprintf(path, sizeof path, "/sys/class/power_supply/%s/type",
                 de->d_name);
        type = read_small_file(path);
        if (type && strcmp(type, "Battery") == 0) {
            snprintf(path, sizeof path,
                     "/sys/class/power_supply/%s/capacity", de->d_name);
            cap = read_small_file(path);
            if (cap) { result = atoi(cap); free(cap); }
            free(type);
            break;
        }
        free(type);
    }
    closedir(dir);
    return result;
}

/* Network state: 1 = a non-loopback interface is up, 0 = none, and
 * *is_wifi is set when the up interface looks like a wireless one. */
static int read_network(int *is_wifi)
{
    DIR *dir = opendir("/sys/class/net");
    struct dirent *de;
    int up = 0;
    *is_wifi = 0;
    if (!dir) return 0;
    while ((de = readdir(dir)) != NULL) {
        char path[512], *state;
        if (strcmp(de->d_name, "lo") == 0 || de->d_name[0] == '.')
            continue;
        snprintf(path, sizeof path, "/sys/class/net/%s/operstate",
                 de->d_name);
        state = read_small_file(path);
        if (state && strcmp(state, "up") == 0) {
            up = 1;
            if (de->d_name[0] == 'w') *is_wifi = 1;
            free(state);
            break;
        }
        free(state);
    }
    closedir(dir);
    return up;
}

/* Volume 0-100 from amixer, or -1 when unavailable. Polled at most
 * once every few seconds by the panel refresh logic. */
static int read_volume(void)
{
    FILE *fp = popen("amixer get Master 2>/dev/null", "r");
    char buf[512];
    int vol = -1;
    if (!fp) return -1;
    while (fgets(buf, sizeof buf, fp)) {
        char *pct = strchr(buf, '[');
        if (pct && strchr(pct, '%')) { vol = atoi(pct + 1); break; }
    }
    pclose(fp);
    return vol;
}

/* "11/21 (土)" style date + "15:52" time, from local time (the OS
 * pins the timezone to Asia/Tokyo, so local time is JST). */
static void format_clock(char *date_out, size_t dsz,
                         char *time_out, size_t tsz)
{
    static const char *wday[] = { "日", "月", "火", "水", "木", "金", "土" };
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    snprintf(date_out, dsz, "%d/%d (%s)", tmv.tm_mon + 1, tmv.tm_mday,
             wday[tmv.tm_wday]);
    snprintf(time_out, tsz, "%02d:%02d", tmv.tm_hour, tmv.tm_min);
}

/* ------------------------------------------------------------------ */
/* Wallpaper                                                           */
/* ------------------------------------------------------------------ */

/* Show the wallpaper on the root window. With Imlib2 the PNG is
 * scaled to fill the screen; without it the desktop is plain
 * charcoal (the build for the real image enables Imlib2). */
static void set_wallpaper(const char *path)
{
#ifdef HAVE_IMLIB2
    Imlib_Image img = imlib_load_image(path);
    if (img) {
        Pixmap pm;
        imlib_context_set_image(img);
        /* Imlib2 needs the X context (display/visual/colormap) set
         * before rendering to a drawable; without it the render
         * dereferences a NULL display and segfaults. */
        imlib_context_set_display(dpy);
        imlib_context_set_visual(DefaultVisual(dpy, scr));
        imlib_context_set_colormap(DefaultColormap(dpy, scr));
        pm = XCreatePixmap(dpy, root, sw, sh, DefaultDepth(dpy, scr));
        imlib_context_set_drawable(pm);
        imlib_render_image_on_drawable_at_size(0, 0, sw, sh);
        XSetWindowBackgroundPixmap(dpy, root, pm);
        XChangeProperty(dpy, root, xa_xrootpmap_id, XA_PIXMAP, 32,
                        PropModeReplace, (unsigned char *)&pm, 1);
        XClearWindow(dpy, root);
        imlib_free_image();
        return;
    }
    fprintf(stderr, "34os-wm: wallpaper not found: %s\n", path);
#endif
    (void)path;
    XSetWindowBackground(dpy, root, px_desktop);
    XClearWindow(dpy, root);
}

/* ------------------------------------------------------------------ */
/* Menu definitions and actions                                        */
/* ------------------------------------------------------------------ */

static const MenuItem main_menu[] = {
    { "Firefox",      ACT_BROWSER,       False },
    { "書庫",         ACT_FILES,         False },
    { "ターミナル",   ACT_TERMINAL,      False },
    { "タイプライター", ACT_WRITER,      False },
    { "電卓",         ACT_CALC,          False },
    { "壁紙",         ACT_SUB_WALLPAPER, True  },
    { "壁紙フォルダ", ACT_WALLPAPER_DIR, False },
    { "共感通信",     ACT_SUB_KYOKAN,    True  },
    { "作業場",       ACT_WORKSPACES,    False },
    { "設定",         ACT_SETTINGS,      False },
    { "CLIに戻る",    ACT_TO_CLI,        False },
    { "再起動",       ACT_REBOOT,        False },
    { "シャットダウン", ACT_POWEROFF,    False },
};
#define MAIN_MENU_COUNT (sizeof main_menu / sizeof main_menu[0])

static const MenuItem wallpaper_menu[] = {
    { "加速する動輪", ACT_WP_LOCO,  False },
    { "月影",         ACT_WP_MOON,  False },
    { "道標",         ACT_WP_LIGHT, False },
};
#define WALLPAPER_MENU_COUNT (sizeof wallpaper_menu / sizeof wallpaper_menu[0])

static const MenuItem kyokan_menu[] = {
    { "スタート", ACT_HOTSPOT_ON,  False },
    { "ストップ", ACT_HOTSPOT_OFF, False },
};
#define KYOKAN_MENU_COUNT (sizeof kyokan_menu / sizeof kyokan_menu[0])

static const MenuItem *submenu_items(int parent, int *count)
{
    if (main_menu[parent].action == ACT_SUB_WALLPAPER) {
        *count = WALLPAPER_MENU_COUNT;
        return wallpaper_menu;
    }
    *count = KYOKAN_MENU_COUNT;
    return kyokan_menu;
}

/* --- Placeholder actions: behaviour not decided yet. -------------- */

/* 作業場 (workspaces): v2.1 ships with a single workspace, so this
 * is a no-op placeholder until multi-workspace support lands. */
static void action_workspaces(void)
{
    /* TODO(v2.1+): workspace switcher. Single workspace for now. */
}

/* 設定 (settings): no settings program exists yet. Placeholder so
 * the menu entry has a home when the settings UI is written. */
static void action_settings(void)
{
    /* TODO(v2.1+): open the 34OS settings program. */
}

/* CLIに戻る: leaving the WM ends the X session; the session script
 * then returns to the CLI login, which is exactly what gocli does
 * under Fluxbox (it kills the WM). So quitting is the real action. */
static void action_to_cli(void)
{
    running = False;
}

/* --- Real actions -------------------------------------------------- */

static void run_action(enum Action a)
{
    const char *home = getenv("HOME");
    char pics[512];
    switch (a) {
    case ACT_BROWSER: {
        const char *const cmd[] = { "/usr/local/bin/browser", NULL };
        spawn(cmd); break; }
    case ACT_FILES: {
        const char *const cmd[] = { "/usr/bin/pcmanfm", NULL };
        spawn(cmd); break; }
    case ACT_TERMINAL: {
        const char *const cmd[] = { "/usr/bin/sakura", NULL };
        spawn(cmd); break; }
    case ACT_WRITER: {
        const char *const cmd[] = { "/usr/bin/abiword", NULL };
        spawn(cmd); break; }
    case ACT_CALC: {
        const char *const cmd[] = { "/usr/bin/galculator", NULL };
        spawn(cmd); break; }
    case ACT_WALLPAPER_DIR: {
        snprintf(pics, sizeof pics, "%s/Pictures", home ? home : "/home/user");
        const char *const cmd[] = { "/usr/bin/pcmanfm", pics, NULL };
        spawn(cmd); break; }
    case ACT_WP_LOCO:
        set_wallpaper(WALLPAPER_DIR "/steam-locomotive.png"); break;
    case ACT_WP_MOON:
        set_wallpaper(WALLPAPER_DIR "/mountain-moon.png"); break;
    case ACT_WP_LIGHT:
        set_wallpaper(WALLPAPER_DIR "/lighthouse.png"); break;
    case ACT_HOTSPOT_ON: {
        const char *const cmd[] = { "/usr/local/bin/34os-hotspot", "on", NULL };
        spawn(cmd); break; }
    case ACT_HOTSPOT_OFF: {
        const char *const cmd[] = { "/usr/local/bin/34os-hotspot", "off", NULL };
        spawn(cmd); break; }
    case ACT_WORKSPACES: action_workspaces(); break;
    case ACT_SETTINGS:    action_settings();    break;
    case ACT_TO_CLI:      action_to_cli();      break;
    case ACT_REBOOT: {
        const char *const cmd[] = { "sudo", "-n", "/usr/bin/systemctl",
                                    "reboot", NULL };
        spawn(cmd); break; }
    case ACT_POWEROFF: {
        const char *const cmd[] = { "sudo", "-n", "/usr/bin/systemctl",
                                    "poweroff", NULL };
        spawn(cmd); break; }
    default: break;
    }
}

/* ------------------------------------------------------------------ */
/* Client management                                                   */
/* ------------------------------------------------------------------ */

static Client *find_client(Window w)
{
    Client *c;
    for (c = clients; c; c = c->next)
        if (c->win == w || c->frame == w) return c;
    return NULL;
}

static int frame_w(const Client *c) { return c->w + 2 * BORDER_W; }
static int frame_h(const Client *c)
{
    return c->h + TITLE_H + BORDER_W + (c->fullscreen ? -TITLE_H - BORDER_W : 0);
}

/* Keep the frame and the client window in sync with c->x/y/w/h. */
static void apply_geometry(Client *c)
{
    if (c->fullscreen) {
        XMoveResizeWindow(dpy, c->frame, 0, 0, sw, sh);
        XMoveResizeWindow(dpy, c->win, 0, 0, sw, sh);
        return;
    }
    XMoveResizeWindow(dpy, c->frame, c->x, c->y, frame_w(c), frame_h(c));
    XMoveResizeWindow(dpy, c->win, BORDER_W, TITLE_H, c->w, c->h);
}

/* Tell the client where its frame edges are (EWMH). */
static void set_frame_extents(Client *c)
{
    unsigned long ext[4];
    ext[0] = BORDER_W;                 /* left   */
    ext[1] = BORDER_W;                 /* right  */
    ext[2] = TITLE_H;                  /* top    */
    ext[3] = BORDER_W;                 /* bottom */
    XChangeProperty(dpy, c->win, xa_net_frame_extents, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)ext, 4);
}

/* WM_STATE: 1 = normal, 3 = iconic. Some clients watch this. */
static void set_wm_state(Client *c, long state)
{
    unsigned long data[2];
    data[0] = (unsigned long)state;
    data[1] = None;
    XChangeProperty(dpy, c->win, xa_wm_state, xa_wm_state, 32,
                    PropModeReplace, (unsigned char *)data, 2);
}

static void update_client_list(void)
{
    Window *wins = NULL;
    Client *c;
    int n = 0, i = 0;
    for (c = clients; c; c = c->next) n++;
    if (n) {
        wins = malloc(sizeof(Window) * n);
        for (c = clients; c; c = c->next) wins[i++] = c->win;
    }
    XChangeProperty(dpy, root, xa_net_client_list, XA_WINDOW, 32,
                    PropModeReplace, (unsigned char *)wins, n);
    free(wins);
}

/* Fetch the title, preferring _NET_WM_NAME (UTF-8) over WM_NAME. */
static void update_title(Client *c)
{
    XTextProperty tp;
    char **list = NULL;
    int n = 0;
    free(c->title);
    c->title = NULL;
    if (XGetTextProperty(dpy, c->win, &tp, xa_net_wm_name) && tp.value) {
        c->title = strdup((char *)tp.value);
        XFree(tp.value);
    } else if (XGetWMName(dpy, c->win, &tp) && tp.value) {
        if (XmbTextPropertyToTextList(dpy, &tp, &list, &n) >= Success
            && n > 0 && list[0]) {
            c->title = strdup(list[0]);
            XFreeStringList(list);
        } else {
            c->title = strdup((char *)tp.value);
        }
        XFree(tp.value);
    }
    if (!c->title) c->title = strdup("(無題)");
}

/* Draw the frame: title bar, buttons, resize grip. Flat lines only. */
static void draw_frame(Client *c)
{
    int fw = c->fullscreen ? sw : frame_w(c);
    int fh = c->fullscreen ? sh : frame_h(c);
    Bool active = (c == focused);
    GC gc = DefaultGC(dpy, scr);
    int bx;

    if (c->fullscreen) return;   /* no decorations in fullscreen */

    /* Title bar background + bottom rule. */
    XSetForeground(dpy, gc, active ? px_title_on : px_title_off);
    XFillRectangle(dpy, c->frame, gc, 0, 0, fw, TITLE_H);
    XSetForeground(dpy, gc, px_frame_line);
    XDrawLine(dpy, c->frame, gc, 0, TITLE_H, fw, TITLE_H);

    /* Title text, left-aligned, clipped before the buttons. */
    draw_text_clip(c->frame, font, active ? &col_text : &col_dim,
                   10, TITLE_H - 9, fw - 10 - 3 * 26, c->title);

    /* Buttons at the right end of the title bar, drawn as line
     * glyphs: minimize (line), maximize (square), close (cross).
     * Order on screen: [min] [max] [close]. */
    bx = fw - 3 * 26;
    XSetForeground(dpy, gc, px_frame_line);
    XDrawLine(dpy, c->frame, gc, bx + 8, TITLE_H / 2 + 4,
              bx + 18, TITLE_H / 2 + 4);                       /* min */
    bx += 26;
    XDrawRectangle(dpy, c->frame, gc, bx + 8, TITLE_H / 2 - 5, 10, 10);
    if (c->maximized)  /* restore glyph: offset second square */
        XDrawRectangle(dpy, c->frame, gc, bx + 11, TITLE_H / 2 - 8, 10, 10);
    bx += 26;
    XDrawLine(dpy, c->frame, gc, bx + 8, TITLE_H / 2 - 5,
              bx + 18, TITLE_H / 2 + 5);                       /* close \ */
    XDrawLine(dpy, c->frame, gc, bx + 8, TITLE_H / 2 + 5,
              bx + 18, TITLE_H / 2 - 5);                       /* close / */

    /* Resize grip: three short diagonal lines, bottom-right. */
    XDrawLine(dpy, c->frame, gc, fw - 5, fh - 1, fw - 1, fh - 5);
    XDrawLine(dpy, c->frame, gc, fw - 10, fh - 1, fw - 1, fh - 10);
    XDrawLine(dpy, c->frame, gc, fw - 15, fh - 1, fw - 1, fh - 15);
}

static void focus_client(Client *c)
{
    Client *old = focused;
    if (focused == c) { if (c) XRaiseWindow(dpy, c->frame); return; }
    focused = c;
    if (old) draw_frame(old);
    if (c) {
        XRaiseWindow(dpy, c->frame);
        XSetInputFocus(dpy, c->win, RevertToParent, CurrentTime);
        XChangeProperty(dpy, root, xa_net_active_window, XA_WINDOW, 32,
                        PropModeReplace, (unsigned char *)&c->win, 1);
        draw_frame(c);
    } else {
        XDeleteProperty(dpy, root, xa_net_active_window);
        XSetInputFocus(dpy, root, RevertToPointerRoot, CurrentTime);
    }
}

/* Decide whether a new window is a dialog, and find its parent. */
static Window transient_parent(Window w)
{
    Window parent = None;
    XGetTransientForHint(dpy, w, &parent);
    return parent;
}

static Bool has_dialog_type(Window w)
{
    Atom actual;
    int format;
    unsigned long nitems, after;
    unsigned char *data = NULL;
    Bool found = False;
    if (XGetWindowProperty(dpy, w, xa_net_wm_window_type, 0, 8, False,
                           XA_ATOM, &actual, &format, &nitems, &after,
                           &data) == Success && data) {
        Atom *types = (Atom *)data;
        unsigned long i;
        for (i = 0; i < nitems; i++)
            if (types[i] == xa_net_wm_window_type_dialog) found = True;
        XFree(data);
    }
    return found;
}

/* Start managing a window: build its frame and reparent it. */
static void manage(Window w)
{
    XWindowAttributes attr;
    XSizeHints hints;
    long supplied = 0;
    Client *c, *parent_c = NULL;
    Window tp;
    unsigned long border_color;

    if (w == panel || w == menu_win || w == submenu_win) {
        XMapWindow(dpy, w);
        return;
    }
    if (find_client(w)) return;
    if (!XGetWindowAttributes(dpy, w, &attr)) return;
    if (attr.override_redirect) return;

    c = calloc(1, sizeof *c);
    c->win = w;
    c->w = attr.width > 0 ? attr.width : 480;
    c->h = attr.height > 0 ? attr.height : 320;
    c->x = attr.x;
    c->y = attr.y;

    if (XGetWMNormalHints(dpy, w, &hints, &supplied)
        && (hints.flags & PMinSize)) {
        c->min_w = hints.min_width;
        c->min_h = hints.min_height;
    }

    tp = transient_parent(w);
    c->is_dialog = has_dialog_type(w) || tp != None;
    if (tp != None) parent_c = find_client(tp);

    /* Dialogs open centred over their parent (or the screen). */
    if (c->is_dialog) {
        if (parent_c) {
            c->x = parent_c->x + (frame_w(parent_c) - frame_w(c)) / 2;
            c->y = parent_c->y + (frame_h(parent_c) - frame_h(c)) / 2;
        } else {
            c->x = (sw - frame_w(c)) / 2;
            c->y = (sh - PANEL_H - frame_h(c)) / 2;
        }
    }
    /* Keep the frame on the screen and above the panel. */
    if (c->x < 0) c->x = 0;
    if (c->y < 0) c->y = 0;
    if (c->y + frame_h(c) > sh - PANEL_H) c->y = sh - PANEL_H - frame_h(c);
    if (c->y < 0) c->y = 0;

    border_color = px_frame_line;
    c->frame = XCreateSimpleWindow(dpy, root, c->x, c->y,
                                   frame_w(c), frame_h(c), BORDER_W,
                                   border_color, px_title_off);
    XSelectInput(dpy, c->frame,
                 ExposureMask | ButtonPressMask | ButtonReleaseMask
                 | PointerMotionMask | SubstructureRedirectMask
                 | SubstructureNotifyMask);
    XSelectInput(dpy, w,
                 EnterWindowMask | PropertyChangeMask | FocusChangeMask
                 | StructureNotifyMask);
    /* Click-to-focus: swallow the click, focus, then replay it. */
    XGrabButton(dpy, Button1, AnyModifier, w, False,
                ButtonPressMask, GrabModeSync, GrabModeAsync, None, None);

    XAddToSaveSet(dpy, w);
    XReparentWindow(dpy, w, c->frame, BORDER_W, TITLE_H);
    XMapWindow(dpy, c->frame);
    XMapWindow(dpy, w);

    c->next = clients;
    clients = c;
    update_title(c);
    set_frame_extents(c);
    set_wm_state(c, 1);
    XChangeProperty(dpy, w, xa_net_wm_desktop, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)&(unsigned long){0}, 1);
    update_client_list();
    draw_frame(c);
    focus_client(c);
    XRaiseWindow(dpy, panel);
}

/* Stop managing a window (it was destroyed or withdrawn). */
static void unmanage(Client *c, Bool reparent_back)
{
    Client **pp;
    for (pp = &clients; *pp && *pp != c; pp = &(*pp)->next) ;
    if (*pp) *pp = c->next;
    if (reparent_back) {
        XReparentWindow(dpy, c->win, root, c->x, c->y);
        XRemoveFromSaveSet(dpy, c->win);
    }
    XDestroyWindow(dpy, c->frame);
    if (focused == c) {
        focused = NULL;
        focus_client(clients);  /* fall back to the newest window */
    }
    free(c->title);
    free(c);
    update_client_list();
}

/* --- Window state changes ------------------------------------------ */

static void iconify(Client *c)
{
    c->iconic = True;
    set_wm_state(c, 3);
    XUnmapWindow(dpy, c->win);
    XUnmapWindow(dpy, c->frame);
    if (focused == c) { focused = NULL; focus_client(NULL); }
}

static void deiconify(Client *c)
{
    c->iconic = False;
    set_wm_state(c, 1);
    XMapWindow(dpy, c->win);
    XMapWindow(dpy, c->frame);
    focus_client(c);
}

static void set_maximized(Client *c, Bool on)
{
    if (c->fullscreen || c->maximized == on) return;
    if (on) {
        c->saved_x = c->x; c->saved_y = c->y;
        c->saved_w = c->w; c->saved_h = c->h;
        c->x = 0; c->y = 0;
        c->w = sw - 2 * BORDER_W;
        c->h = sh - PANEL_H - TITLE_H - BORDER_W;
        c->maximized = True;
    } else {
        c->x = c->saved_x; c->y = c->saved_y;
        c->w = c->saved_w; c->h = c->saved_h;
        c->maximized = False;
    }
    apply_geometry(c);
    draw_frame(c);
}

static void set_fullscreen(Client *c, Bool on)
{
    if (c->fullscreen == on) return;
    if (on) {
        if (!c->maximized) {
            c->saved_x = c->x; c->saved_y = c->y;
            c->saved_w = c->w; c->saved_h = c->h;
        }
        c->fullscreen = True;
        apply_geometry(c);
        XRaiseWindow(dpy, c->frame);   /* above the panel */
    } else {
        c->fullscreen = False;
        if (!c->maximized) {
            c->x = c->saved_x; c->y = c->saved_y;
            c->w = c->saved_w; c->h = c->saved_h;
        }
        apply_geometry(c);
        XRaiseWindow(dpy, panel);
    }
    draw_frame(c);
}

/* Ask a client to close (WM_DELETE_WINDOW), kill it if it refuses
 * to declare the protocol. */
static void close_client(Client *c)
{
    Atom *protocols = NULL;
    int n = 0, i;
    Bool has_delete = False;
    if (XGetWMProtocols(dpy, c->win, &protocols, &n)) {
        for (i = 0; i < n; i++)
            if (protocols[i] == xa_wm_delete) has_delete = True;
        XFree(protocols);
    }
    if (has_delete) {
        XEvent ev;
        memset(&ev, 0, sizeof ev);
        ev.type = ClientMessage;
        ev.xclient.window = c->win;
        ev.xclient.message_type = xa_wm_protocols;
        ev.xclient.format = 32;
        ev.xclient.data.l[0] = (long)xa_wm_delete;
        ev.xclient.data.l[1] = CurrentTime;
        XSendEvent(dpy, c->win, False, NoEventMask, &ev);
    } else {
        XKillClient(dpy, c->win);
    }
}

/* ------------------------------------------------------------------ */
/* Panel, start menu, mouse handling, event loop, main                 */
/* ------------------------------------------------------------------ */

#include <X11/keysym.h>

static void open_menu(void);
static void close_menu(void);
static void draw_panel(void);

/* ------------------------------------------------------------------ */
/* Panel                                                               */
/* ------------------------------------------------------------------ */

/* Cached indicator values, refreshed by refresh_indicators(). */
static int ind_battery = -1;       /* -1 = no battery        */
static int ind_volume  = -1;       /* -1 = unavailable       */
static int ind_net_up  = 0;
static int ind_wifi    = 0;

static void refresh_indicators(Bool force)
{
    static time_t last_vol = 0;
    time_t now = time(NULL);
    ind_battery = read_battery();
    ind_net_up = read_network(&ind_wifi);
    if (force || now - last_vol >= 5) {   /* amixer is a subprocess */
        ind_volume = read_volume();
        last_vol = now;
    }
}

/* Task button rectangles from the last draw_panel(), for clicks. */
#define MAX_TASKBTNS 64
static struct { Client *c; int x, w; } taskbtns[MAX_TASKBTNS];
static int taskbtn_count = 0;

static Bool client_alive(Client *c)
{
    Client *p;
    for (p = clients; p; p = p->next)
        if (p == c) return True;
    return False;
}

/* Baseline y that vertically centres font f inside a box of
 * height h whose top edge is at y0. */
static int centred_baseline(XftFont *f, int y0, int h)
{
    return y0 + (h - (f->ascent + f->descent)) / 2 + f->ascent;
}

static void draw_panel(void)
{
    GC gc = DefaultGC(dpy, scr);
    Client *c;
    char date[32], timestr[16], clockbuf[64];
    char ind[3][40];
    int ind_ws[3];
    int ind_n = 0, ind_w_total = 0, clock_w, ind_x, tasks_right;
    int n, i, tx, avail, bw;

    if (!panel) return;

    /* Layout first: clock at the right edge, indicators to its
     * left, task buttons in whatever room remains. */
    format_clock(date, sizeof date, timestr, sizeof timestr);
    snprintf(clockbuf, sizeof clockbuf, "%s  %s", date, timestr);
    clock_w = text_w(font_big, clockbuf);

    if (ind_net_up)
        snprintf(ind[ind_n], sizeof ind[0], "%s", ind_wifi ? "WiFi" : "有線");
    else
        snprintf(ind[ind_n], sizeof ind[0], "%s", "未接続");
    ind_n++;
    if (ind_volume >= 0) {
        snprintf(ind[ind_n], sizeof ind[0], "音量 %d%%", ind_volume);
        ind_n++;
    }
    if (ind_battery >= 0) {
        snprintf(ind[ind_n], sizeof ind[0], "電池 %d%%", ind_battery);
        ind_n++;
    }
    for (i = 0; i < ind_n; i++) {
        ind_ws[i] = text_w(font, ind[i]);
        ind_w_total += ind_ws[i] + 16;
    }
    ind_x = sw - 10 - clock_w - 18 - ind_w_total;
    tasks_right = ind_x - 8;

    /* Background + top rule. */
    XSetForeground(dpy, gc, px_panel_bg);
    XFillRectangle(dpy, panel, gc, 0, 0, sw, PANEL_H);
    XSetForeground(dpy, gc, px_panel_line);
    XDrawLine(dpy, panel, gc, 0, 0, sw, 0);

    /* Start button (bottom-left). Highlighted while the menu is up. */
    XSetForeground(dpy, gc, menu_win ? px_task_on : px_task_off);
    XFillRectangle(dpy, panel, gc, 4, 5, STARTBTN_W - 8, PANEL_H - 10);
    XSetForeground(dpy, gc, px_panel_line);
    XDrawRectangle(dpy, panel, gc, 4, 5, STARTBTN_W - 8, PANEL_H - 10);
    draw_text(panel, font_big, &col_text,
              4 + (STARTBTN_W - 8 - text_w(font_big, "34OS")) / 2,
              centred_baseline(font_big, 0, PANEL_H), "34OS");

    /* Task buttons, in client-list order. */
    n = 0;
    for (c = clients; c; c = c->next) n++;
    tx = STARTBTN_W + 8;
    avail = tasks_right - tx;
    taskbtn_count = 0;
    if (n > 0 && avail > 40) {
        bw = avail / n - 4;
        if (bw > TASKBTN_MAXW) bw = TASKBTN_MAXW;
        if (bw < 28) bw = 28;
        i = 0;
        for (c = clients; c && i < MAX_TASKBTNS; c = c->next, i++) {
            int bx = tx + i * (bw + 4);
            int wdt = bw;
            if (bx + wdt > tasks_right) wdt = tasks_right - bx;
            if (wdt < 24) break;
            taskbtns[taskbtn_count].c = c;
            taskbtns[taskbtn_count].x = bx;
            taskbtns[taskbtn_count].w = wdt;
            taskbtn_count++;
            XSetForeground(dpy, gc,
                           (c == focused && !c->iconic)
                           ? px_task_on : px_task_off);
            XFillRectangle(dpy, panel, gc, bx, 6, wdt, PANEL_H - 12);
            XSetForeground(dpy, gc, px_panel_line);
            XDrawRectangle(dpy, panel, gc, bx, 6, wdt, PANEL_H - 12);
            draw_text_clip(panel, font, c->iconic ? &col_dim : &col_text,
                           bx + 8, centred_baseline(font, 0, PANEL_H),
                           wdt - 16, c->title);
        }
    }

    /* Indicators + clock. */
    for (i = 0; i < ind_n; i++) {
        const XftColor *col = (i == 0 && !ind_net_up) ? &col_dim : &col_text;
        draw_text(panel, font, col, ind_x,
                  centred_baseline(font, 0, PANEL_H), ind[i]);
        ind_x += ind_ws[i] + 16;
    }
    draw_text(panel, font_big, &col_text, sw - 10 - clock_w,
              centred_baseline(font_big, 0, PANEL_H), clockbuf);
    XFlush(dpy);
}

static void panel_click(int x, int button)
{
    int i;
    if (button != Button1) return;
    if (x < STARTBTN_W) {
        if (menu_win) close_menu();
        else open_menu();
        return;
    }
    for (i = 0; i < taskbtn_count; i++) {
        if (x >= taskbtns[i].x && x < taskbtns[i].x + taskbtns[i].w) {
            Client *c = taskbtns[i].c;
            if (!client_alive(c)) { draw_panel(); return; }
            if (c->iconic) deiconify(c);
            else focus_client(c);
            draw_panel();
            return;
        }
    }
}

static void create_panel(void)
{
    XSetWindowAttributes attr;
    unsigned long strut_partial[12];
    unsigned long strut[4];
    Atom xa_net_wm_strut;
    int i;

    attr.override_redirect = True;
    attr.background_pixel = px_panel_bg;
    attr.event_mask = ExposureMask | ButtonPressMask;
    panel = XCreateWindow(dpy, root, 0, sh - PANEL_H,
                          (unsigned)sw, PANEL_H, 1,
                          CopyFromParent, InputOutput, CopyFromParent,
                          CWOverrideRedirect | CWBackPixel | CWEventMask,
                          &attr);
    XSetWindowBorder(dpy, panel, px_panel_line);
    XChangeProperty(dpy, panel, xa_net_wm_window_type, XA_ATOM, 32,
                    PropModeReplace,
                    (unsigned char *)&xa_net_wm_window_type_dock, 1);
    for (i = 0; i < 12; i++) strut_partial[i] = 0;
    strut_partial[3] = PANEL_H;                    /* bottom        */
    strut_partial[10] = 0;                         /* bottom start  */
    strut_partial[11] = (unsigned long)(sw - 1);   /* bottom end    */
    XChangeProperty(dpy, panel, xa_net_wm_strut_partial, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)strut_partial, 12);
    xa_net_wm_strut = XInternAtom(dpy, "_NET_WM_STRUT", False);
    strut[0] = strut[1] = strut[2] = 0;
    strut[3] = PANEL_H;
    XChangeProperty(dpy, panel, xa_net_wm_strut, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)strut, 4);
    XMapWindow(dpy, panel);
}

/* ------------------------------------------------------------------ */
/* Start menu + submenus                                               */
/* ------------------------------------------------------------------ */

static int menu_y;                 /* root y of the main menu       */
static int submenu_x, submenu_y;   /* root position of the submenu  */
static int submenu_count;          /* item count of the open submenu */

static void close_submenu(void)
{
    if (submenu_win) {
        XDestroyWindow(dpy, submenu_win);
        submenu_win = 0;
    }
    submenu_parent = -1;
    submenu_hover = -1;
    submenu_count = 0;
}

static void close_menu(void)
{
    if (!menu_win) return;
    close_submenu();
    XDestroyWindow(dpy, menu_win);
    menu_win = 0;
    menu_hover = -1;
    XUngrabPointer(dpy, CurrentTime);
    XUngrabKeyboard(dpy, CurrentTime);
    draw_panel();
}

static void draw_menu(void)
{
    GC gc = DefaultGC(dpy, scr);
    int i, count = (int)MAIN_MENU_COUNT;
    if (!menu_win) return;
    XSetForeground(dpy, gc, px_menu_bg);
    XFillRectangle(dpy, menu_win, gc, 0, 0, MENU_W, count * MENU_ITEM_H);
    for (i = 0; i < count; i++) {
        int y0 = i * MENU_ITEM_H;
        if (i == menu_hover) {
            XSetForeground(dpy, gc, px_menu_hover);
            XFillRectangle(dpy, menu_win, gc, 0, y0, MENU_W, MENU_ITEM_H);
        }
        draw_text(menu_win, font, &col_text, 12,
                  centred_baseline(font, y0, MENU_ITEM_H),
                  main_menu[i].label);
        if (main_menu[i].has_submenu) {   /* ">" line glyph */
            int cy = y0 + MENU_ITEM_H / 2;
            XSetForeground(dpy, gc, px_frame_line);
            XDrawLine(dpy, menu_win, gc, MENU_W - 18, cy - 5,
                      MENU_W - 10, cy);
            XDrawLine(dpy, menu_win, gc, MENU_W - 10, cy,
                      MENU_W - 18, cy + 5);
        }
    }
}

static void draw_submenu(void)
{
    GC gc = DefaultGC(dpy, scr);
    const MenuItem *items;
    int count, i;
    if (!submenu_win || submenu_parent < 0) return;
    items = submenu_items(submenu_parent, &count);
    XSetForeground(dpy, gc, px_menu_bg);
    XFillRectangle(dpy, submenu_win, gc, 0, 0, MENU_W, count * MENU_ITEM_H);
    for (i = 0; i < count; i++) {
        int y0 = i * MENU_ITEM_H;
        if (i == submenu_hover) {
            XSetForeground(dpy, gc, px_menu_hover);
            XFillRectangle(dpy, submenu_win, gc, 0, y0,
                           MENU_W, MENU_ITEM_H);
        }
        draw_text(submenu_win, font, &col_text, 12,
                  centred_baseline(font, y0, MENU_ITEM_H), items[i].label);
    }
}

static void open_submenu(int parent)
{
    XSetWindowAttributes attr;
    int count, h;
    if (submenu_win && submenu_parent == parent) return;
    close_submenu();
    (void)submenu_items(parent, &count);
    submenu_count = count;
    submenu_parent = parent;
    submenu_hover = -1;
    h = count * MENU_ITEM_H;
    submenu_x = MENU_W;
    submenu_y = menu_y + parent * MENU_ITEM_H;
    if (submenu_y + h > sh - PANEL_H) submenu_y = sh - PANEL_H - h;
    if (submenu_y < 0) submenu_y = 0;
    attr.override_redirect = True;
    attr.background_pixel = px_menu_bg;
    attr.event_mask = ExposureMask;
    submenu_win = XCreateWindow(dpy, root, submenu_x, submenu_y,
                                MENU_W, (unsigned)h, 1,
                                CopyFromParent, InputOutput, CopyFromParent,
                                CWOverrideRedirect | CWBackPixel
                                | CWEventMask, &attr);
    XSetWindowBorder(dpy, submenu_win, px_frame_line);
    XMapWindow(dpy, submenu_win);
    draw_submenu();
}

static void open_menu(void)
{
    XSetWindowAttributes attr;
    int h = (int)MAIN_MENU_COUNT * MENU_ITEM_H;
    if (menu_win) return;
    menu_y = sh - PANEL_H - h;
    if (menu_y < 0) menu_y = 0;
    attr.override_redirect = True;
    attr.background_pixel = px_menu_bg;
    attr.event_mask = ExposureMask;
    menu_win = XCreateWindow(dpy, root, 0, menu_y, MENU_W, (unsigned)h, 1,
                             CopyFromParent, InputOutput, CopyFromParent,
                             CWOverrideRedirect | CWBackPixel | CWEventMask,
                             &attr);
    XSetWindowBorder(dpy, menu_win, px_frame_line);
    menu_hover = -1;
    XMapWindow(dpy, menu_win);
    /* Grab pointer + keyboard so clicks outside the menu and the
     * Escape key reach us wherever the pointer is. */
    XGrabPointer(dpy, root, False,
                 ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
                 GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
    XGrabKeyboard(dpy, root, False, GrabModeAsync, GrabModeAsync,
                  CurrentTime);
    draw_menu();
    draw_panel();
}

static void menu_motion(int xr, int yr)
{
    int mh = (int)MAIN_MENU_COUNT * MENU_ITEM_H;
    if (xr >= 0 && xr < MENU_W && yr >= menu_y && yr < menu_y + mh) {
        int idx = (yr - menu_y) / MENU_ITEM_H;
        if (idx != menu_hover) {
            menu_hover = idx;
            draw_menu();
            if (main_menu[idx].has_submenu) open_submenu(idx);
            else if (submenu_win) close_submenu();
        }
        return;
    }
    if (submenu_win && xr >= submenu_x && xr < submenu_x + MENU_W
        && yr >= submenu_y && yr < submenu_y + submenu_count * MENU_ITEM_H) {
        int idx = (yr - submenu_y) / MENU_ITEM_H;
        if (idx != submenu_hover) {
            submenu_hover = idx;
            draw_submenu();
        }
        return;
    }
    if (menu_hover != -1) { menu_hover = -1; draw_menu(); }
    if (submenu_hover != -1) { submenu_hover = -1; draw_submenu(); }
}

static void menu_click(int xr, int yr, int button)
{
    int mh = (int)MAIN_MENU_COUNT * MENU_ITEM_H;
    if (button != Button1) return;
    if (submenu_win && xr >= submenu_x && xr < submenu_x + MENU_W
        && yr >= submenu_y && yr < submenu_y + submenu_count * MENU_ITEM_H) {
        int idx = (yr - submenu_y) / MENU_ITEM_H;
        int count;
        const MenuItem *items = submenu_items(submenu_parent, &count);
        enum Action a;
        if (idx < 0 || idx >= count) return;
        a = items[idx].action;
        close_menu();
        run_action(a);
        return;
    }
    if (xr >= 0 && xr < MENU_W && yr >= menu_y && yr < menu_y + mh) {
        int idx = (yr - menu_y) / MENU_ITEM_H;
        if (main_menu[idx].has_submenu) {
            menu_hover = idx;
            open_submenu(idx);
            draw_menu();
            return;
        }
        {
            enum Action a = main_menu[idx].action;
            close_menu();
            run_action(a);
        }
        return;
    }
    /* Anywhere else, including the start button again: just close. */
    close_menu();
}

/* ------------------------------------------------------------------ */
/* Mouse handling                                                      */
/* ------------------------------------------------------------------ */

/* Tell a client its current geometry in root coordinates (ICCCM
 * synthetic ConfigureNotify), so it can place dialogs correctly. */
static void send_configure(Client *c)
{
    XEvent ev;
    memset(&ev, 0, sizeof ev);
    ev.type = ConfigureNotify;
    ev.xconfigure.display = dpy;
    ev.xconfigure.event = c->win;
    ev.xconfigure.window = c->win;
    ev.xconfigure.x = c->x + BORDER_W;
    ev.xconfigure.y = c->y + TITLE_H;
    ev.xconfigure.width = c->w;
    ev.xconfigure.height = c->h;
    ev.xconfigure.border_width = 0;
    ev.xconfigure.above = None;
    ev.xconfigure.override_redirect = False;
    XSendEvent(dpy, c->win, False, StructureNotifyMask, &ev);
}

static void frame_press(Client *c, XButtonEvent *e)
{
    int fw = frame_w(c), fh = frame_h(c);
    focus_client(c);
    draw_panel();
    if (e->button != Button1 || c->fullscreen) return;
    if (e->y < TITLE_H) {
        /* Button cells, right to left: close, maximise, minimise. */
        if (e->x >= fw - 26) { close_client(c); return; }
        if (e->x >= fw - 52) { set_maximized(c, !c->maximized); return; }
        if (e->x >= fw - 78) { iconify(c); draw_panel(); return; }
        if (c->maximized) return;
        drag.mode = 1;                       /* move */
    } else if (e->x >= fw - GRIP && e->y >= fh - GRIP) {
        if (c->maximized) return;
        drag.mode = 2;                       /* resize */
    } else {
        return;
    }
    drag.c = c;
    drag.start_x = e->x_root;
    drag.start_y = e->y_root;
    drag.orig_x = c->x;
    drag.orig_y = c->y;
    drag.orig_w = c->w;
    drag.orig_h = c->h;
}

static void handle_motion(XMotionEvent *e)
{
    Client *c;
    int dx, dy, minw, minh;
    if (menu_win) { menu_motion(e->x_root, e->y_root); return; }
    if (!drag.c || drag.mode == 0) return;
    c = drag.c;
    if (!client_alive(c)) { drag.c = NULL; drag.mode = 0; return; }
    dx = e->x_root - drag.start_x;
    dy = e->y_root - drag.start_y;
    if (drag.mode == 1) {
        c->x = drag.orig_x + dx;
        c->y = drag.orig_y + dy;
        if (c->y < 0) c->y = 0;
        if (c->y > sh - PANEL_H - TITLE_H) c->y = sh - PANEL_H - TITLE_H;
        if (c->x < -(frame_w(c) - 60)) c->x = -(frame_w(c) - 60);
        if (c->x > sw - 60) c->x = sw - 60;
        XMoveWindow(dpy, c->frame, c->x, c->y);
    } else if (drag.mode == 2) {
        minw = c->min_w > MIN_W ? c->min_w : MIN_W;
        minh = c->min_h > MIN_H ? c->min_h : MIN_H;
        c->w = drag.orig_w + dx;
        c->h = drag.orig_h + dy;
        if (c->w < minw) c->w = minw;
        if (c->h < minh) c->h = minh;
        apply_geometry(c);
    }
}

static void handle_button_press(XButtonEvent *e)
{
    Client *c;
    if (menu_win) {          /* pointer is grabbed to the root window */
        menu_click(e->x_root, e->y_root, (int)e->button);
        return;
    }
    if (e->window == panel) {
        panel_click(e->x, (int)e->button);
        return;
    }
    c = find_client(e->window);
    if (!c) return;
    if (e->window == c->win) {
        /* Passive grab from manage(): focus, then replay the click
         * so the application still sees it. */
        focus_client(c);
        XAllowEvents(dpy, ReplayPointer, e->time);
        draw_panel();
        return;
    }
    if (e->window == c->frame)
        frame_press(c, e);
}

/* ------------------------------------------------------------------ */
/* Event handlers                                                      */
/* ------------------------------------------------------------------ */

static void handle_map_request(XMapRequestEvent *e)
{
    Client *c = find_client(e->window);
    if (c) {
        if (e->window == c->win) {
            if (c->iconic) deiconify(c);
            else {
                XMapWindow(dpy, c->frame);
                XMapWindow(dpy, c->win);
            }
            draw_panel();
        }
        return;
    }
    manage(e->window);
    draw_panel();
}

static void handle_configure_request(XConfigureRequestEvent *e)
{
    Client *c = find_client(e->window);
    XWindowChanges wc;
    int minw, minh;
    if (c) {
        if (e->window != c->win) return;   /* our own frame: ignore */
        if (!c->maximized && !c->fullscreen) {
            if (e->value_mask & CWX)      c->x = e->x - BORDER_W;
            if (e->value_mask & CWY)      c->y = e->y - TITLE_H;
            if (e->value_mask & CWWidth)  c->w = e->width;
            if (e->value_mask & CWHeight) c->h = e->height;
            minw = c->min_w > MIN_W ? c->min_w : MIN_W;
            minh = c->min_h > MIN_H ? c->min_h : MIN_H;
            if (c->w < minw) c->w = minw;
            if (c->h < minh) c->h = minh;
            if (c->y < 0) c->y = 0;
            apply_geometry(c);
            draw_frame(c);
        }
        send_configure(c);
        return;
    }
    wc.x = e->x;
    wc.y = e->y;
    wc.width = e->width;
    wc.height = e->height;
    wc.border_width = e->border_width;
    wc.sibling = e->above;
    wc.stack_mode = e->detail;
    XConfigureWindow(dpy, e->window, e->value_mask, &wc);
}

static void handle_unmap_notify(XUnmapEvent *e)
{
    Client *c = find_client(e->window);
    if (!c || e->window != c->win) return;
    if (c->iconic) return;          /* our own iconify() did this */
    if (drag.c == c) { drag.c = NULL; drag.mode = 0; }
    unmanage(c, True);              /* client withdrew its window */
    draw_panel();
}

static void handle_property_notify(XPropertyEvent *e)
{
    Client *c = find_client(e->window);
    XSizeHints hints;
    long supplied = 0;
    if (!c || e->window != c->win) return;
    if (e->atom == xa_net_wm_name || e->atom == XA_WM_NAME) {
        update_title(c);
        draw_frame(c);
        draw_panel();
    } else if (e->atom == XA_WM_NORMAL_HINTS) {
        if (XGetWMNormalHints(dpy, c->win, &hints, &supplied)
            && (hints.flags & PMinSize)) {
            c->min_w = hints.min_width;
            c->min_h = hints.min_height;
        }
    }
}

static void handle_client_message(XClientMessageEvent *e)
{
    Client *c = find_client(e->window);
    int i;
    if (!c || e->window != c->win) {
        if (e->message_type == xa_net_active_window && c) {
            /* a frame window cannot be activated; ignore */
        }
        return;
    }
    if (e->message_type == xa_net_active_window) {
        if (c->iconic) deiconify(c);
        else focus_client(c);
        draw_panel();
    } else if (e->message_type == xa_net_close_window) {
        close_client(c);
    } else if (e->message_type == xa_net_wm_state) {
        long action = e->data.l[0];   /* 0 remove, 1 add, 2 toggle */
        for (i = 1; i <= 2; i++) {
            Atom a = (Atom)e->data.l[i];
            if (a == xa_net_wm_state_fullscreen) {
                Bool on = (action == 1) || (action == 2 && !c->fullscreen);
                set_fullscreen(c, on);
            } else if (a == xa_net_wm_state_max_horz
                       || a == xa_net_wm_state_max_vert) {
                Bool on = (action == 1) || (action == 2 && !c->maximized);
                set_maximized(c, on);
            }
        }
        draw_panel();
    }
}

static void dispatch(XEvent *ev)
{
    Client *c;
    switch (ev->type) {
    case MapRequest:
        handle_map_request(&ev->xmaprequest);
        break;
    case ConfigureRequest:
        handle_configure_request(&ev->xconfigurerequest);
        break;
    case UnmapNotify:
        handle_unmap_notify(&ev->xunmap);
        break;
    case DestroyNotify:
        c = find_client(ev->xdestroywindow.window);
        if (c && ev->xdestroywindow.window == c->win) {
            if (drag.c == c) { drag.c = NULL; drag.mode = 0; }
            unmanage(c, False);
            draw_panel();
        }
        break;
    case PropertyNotify:
        handle_property_notify(&ev->xproperty);
        break;
    case ClientMessage:
        handle_client_message(&ev->xclient);
        break;
    case ButtonPress:
        handle_button_press(&ev->xbutton);
        break;
    case ButtonRelease:
        if (drag.c) {
            if (drag.mode) send_configure(drag.c);
            drag.c = NULL;
            drag.mode = 0;
        }
        break;
    case MotionNotify:
        handle_motion(&ev->xmotion);
        break;
    case KeyPress:
        if (menu_win && XLookupKeysym(&ev->xkey, 0) == XK_Escape)
            close_menu();
        break;
    case Expose:
        if (ev->xexpose.count != 0) break;
        if (ev->xexpose.window == panel) draw_panel();
        else if (menu_win && ev->xexpose.window == menu_win) draw_menu();
        else if (submenu_win && ev->xexpose.window == submenu_win)
            draw_submenu();
        else {
            c = find_client(ev->xexpose.window);
            if (c && ev->xexpose.window == c->frame) draw_frame(c);
        }
        break;
    default:
        break;
    }
}

static void event_loop(void)
{
    while (running) {
        while (running && XPending(dpy) > 0) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            dispatch(&ev);
        }
        if (!running) break;
        {
            int fd = ConnectionNumber(dpy);
            fd_set fds;
            struct timeval tv;
            FD_ZERO(&fds);
            FD_SET(fd, &fds);
            tv.tv_sec = 1;
            tv.tv_usec = 0;
            if (select(fd + 1, &fds, NULL, NULL, &tv) == 0) {
                /* 1 s tick: clock + indicators */
                refresh_indicators(False);
                draw_panel();
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

/* Open a UI font. The OS is Japanese-only, so a font without
 * Japanese glyphs is useless even when fontconfig happily returns
 * it: walk the family list until one covers hiragana. On a real
 * 34OS system BIZ UDGothic is installed and matches first. */
static XftFont *open_ui_font(int size, Bool bold)
{
    static const char *families[] = {
        "BIZ UDGothic", "Noto Sans CJK JP", "sans"
    };
    size_t i, n = sizeof families / sizeof families[0];
    char pat[160];
    for (i = 0; i < n; i++) {
        XftFont *f;
        snprintf(pat, sizeof pat, "%s:size=%d%s", families[i], size,
                 bold ? ":weight=bold" : "");
        f = XftFontOpenName(dpy, scr, pat);
        if (!f) continue;
        if (XftCharExists(dpy, f, 0x3042) || i == n - 1)
            return f;
        XftFontClose(dpy, f);
    }
    return NULL;
}

int main(void)
{
    Window tree_root, tree_parent, *kids;
    unsigned int nkids, i;
    unsigned long one = 1, zero = 0;
    Atom supported[16];
    int nsup = 0;

    signal(SIGCHLD, SIG_IGN);   /* spawned children reap themselves */

    dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "34os-wm: cannot open display\n");
        return 1;
    }
    scr = DefaultScreen(dpy);
    root = RootWindow(dpy, scr);
    sw = DisplayWidth(dpy, scr);
    sh = DisplayHeight(dpy, scr);
    XSetErrorHandler(xerror);

    /* Atoms */
    xa_wm_protocols   = XInternAtom(dpy, "WM_PROTOCOLS", False);
    xa_wm_delete      = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    xa_wm_state       = XInternAtom(dpy, "WM_STATE", False);
    xa_wm_transient   = XInternAtom(dpy, "WM_TRANSIENT_FOR", False);
    xa_net_supported  = XInternAtom(dpy, "_NET_SUPPORTED", False);
    xa_net_client_list = XInternAtom(dpy, "_NET_CLIENT_LIST", False);
    xa_net_active_window = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    xa_net_wm_name    = XInternAtom(dpy, "_NET_WM_NAME", False);
    xa_net_wm_state   = XInternAtom(dpy, "_NET_WM_STATE", False);
    xa_net_wm_state_fullscreen =
        XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
    xa_net_wm_state_max_horz =
        XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_HORZ", False);
    xa_net_wm_state_max_vert =
        XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_VERT", False);
    xa_net_wm_window_type =
        XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    xa_net_wm_window_type_dialog =
        XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DIALOG", False);
    xa_net_wm_window_type_dock =
        XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", False);
    xa_net_close_window = XInternAtom(dpy, "_NET_CLOSE_WINDOW", False);
    xa_net_number_of_desktops =
        XInternAtom(dpy, "_NET_NUMBER_OF_DESKTOPS", False);
    xa_net_current_desktop =
        XInternAtom(dpy, "_NET_CURRENT_DESKTOP", False);
    xa_net_wm_desktop = XInternAtom(dpy, "_NET_WM_DESKTOP", False);
    xa_net_frame_extents = XInternAtom(dpy, "_NET_FRAME_EXTENTS", False);
    xa_net_wm_strut_partial =
        XInternAtom(dpy, "_NET_WM_STRUT_PARTIAL", False);
    xa_xrootpmap_id   = XInternAtom(dpy, "_XROOTPMAP_ID", False);

    /* Colours */
    px_panel_bg   = color_pixel(COL_PANEL_BG);
    px_panel_line = color_pixel(COL_PANEL_LINE);
    px_title_on   = color_pixel(COL_TITLE_ON);
    px_title_off  = color_pixel(COL_TITLE_OFF);
    px_frame_line = color_pixel(COL_FRAME_LINE);
    px_menu_bg    = color_pixel(COL_MENU_BG);
    px_menu_hover = color_pixel(COL_MENU_HOVER);
    px_task_on    = color_pixel(COL_TASK_ON);
    px_task_off   = color_pixel(COL_TASK_OFF);
    px_desktop    = color_pixel(COL_DESKTOP);
    xft_color(COL_TEXT, &col_text);
    xft_color(COL_TEXT_DIM, &col_dim);

    /* Fonts: BIZ UDGothic first, with coverage-checked fallbacks. */
    font = open_ui_font(11, False);
    font_big = open_ui_font(12, True);
    if (!font_big) font_big = font;
    if (!font) {
        fprintf(stderr, "34os-wm: no usable UI font\n");
        return 1;
    }

    create_panel();
    set_wallpaper(WALLPAPER_DEFAULT);

    XSelectInput(dpy, root, SubstructureRedirectMask
                 | SubstructureNotifyMask | ButtonPressMask);

    /* Publish the EWMH atoms we honour. */
    supported[nsup++] = xa_net_supported;
    supported[nsup++] = xa_net_client_list;
    supported[nsup++] = xa_net_active_window;
    supported[nsup++] = xa_net_close_window;
    supported[nsup++] = xa_net_number_of_desktops;
    supported[nsup++] = xa_net_current_desktop;
    supported[nsup++] = xa_net_wm_desktop;
    supported[nsup++] = xa_net_frame_extents;
    supported[nsup++] = xa_net_wm_name;
    supported[nsup++] = xa_net_wm_state;
    supported[nsup++] = xa_net_wm_state_fullscreen;
    supported[nsup++] = xa_net_wm_state_max_horz;
    supported[nsup++] = xa_net_wm_state_max_vert;
    supported[nsup++] = xa_net_wm_window_type;
    supported[nsup++] = xa_net_wm_strut_partial;
    XChangeProperty(dpy, root, xa_net_supported, XA_ATOM, 32,
                    PropModeReplace, (unsigned char *)supported, nsup);
    XChangeProperty(dpy, root, xa_net_number_of_desktops, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)&one, 1);
    XChangeProperty(dpy, root, xa_net_current_desktop, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)&zero, 1);
    update_client_list();

    refresh_indicators(True);
    draw_panel();

    /* Adopt windows that were already mapped. */
    kids = NULL;
    nkids = 0;
    if (XQueryTree(dpy, root, &tree_root, &tree_parent, &kids, &nkids)) {
        for (i = 0; i < nkids; i++)
            manage(kids[i]);
        if (kids) XFree(kids);
    }
    draw_panel();

    event_loop();

    /* Clean exit (CLIに戻る): hand every window back to the root. */
    if (menu_win) close_menu();
    while (clients)
        unmanage(clients, True);
    XCloseDisplay(dpy);
    return 0;
}
