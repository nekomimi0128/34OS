/* Deterministic double-click test for the desk icon column:
 * finds the desk window (116 wide, at 0,0, tall) and sends two
 * ButtonPress/Release pairs to (58, Y) with event times exactly
 * 200 ms apart, so the WM's double-click window is exercised
 * without real-pointer timing noise.
 *   dclick Y */
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static Window find_desk(Display *dpy, Window root)
{
    Window r, p, *kids;
    unsigned int n, i;
    Window found = None;
    if (!XQueryTree(dpy, root, &r, &p, &kids, &n)) return None;
    for (i = 0; i < n; i++) {
        XWindowAttributes a;
        if (XGetWindowAttributes(dpy, kids[i], &a)
            && a.x == 0 && a.y == 0 && a.width == 116 && a.height > 400)
            found = kids[i];
    }
    if (kids) XFree(kids);
    return found;
}

static void send_btn(Display *dpy, Window win, int type, int x, int y,
                     unsigned long t)
{
    XEvent ev;
    memset(&ev, 0, sizeof ev);
    ev.type = type;
    ev.xbutton.display = dpy;
    ev.xbutton.window = win;
    ev.xbutton.root = DefaultRootWindow(dpy);
    ev.xbutton.subwindow = None;
    ev.xbutton.time = t;
    ev.xbutton.x = x;
    ev.xbutton.y = y;
    ev.xbutton.x_root = x;
    ev.xbutton.y_root = y;
    ev.xbutton.state = 0;
    ev.xbutton.button = Button1;
    ev.xbutton.same_screen = True;
    XSendEvent(dpy, win, False, ButtonPressMask | ButtonReleaseMask, &ev);
    XFlush(dpy);
}

int main(int argc, char **argv)
{
    Display *dpy = XOpenDisplay(NULL);
    Window root, desk;
    int y;
    if (!dpy) { fprintf(stderr, "no display\n"); return 1; }
    if (argc != 2) { fprintf(stderr, "usage: dclick Y\n"); return 1; }
    y = atoi(argv[1]);
    root = DefaultRootWindow(dpy);
    desk = find_desk(dpy, root);
    if (!desk) { fprintf(stderr, "desk window not found\n"); return 1; }
    fprintf(stderr, "desk window: 0x%lx\n", desk);
    send_btn(dpy, desk, ButtonPress, 58, y, 1000000);
    send_btn(dpy, desk, ButtonRelease, 58, y, 1000000);
    usleep(50000);
    send_btn(dpy, desk, ButtonPress, 58, y, 1000200);
    send_btn(dpy, desk, ButtonRelease, 58, y, 1000200);
    XCloseDisplay(dpy);
    return 0;
}
