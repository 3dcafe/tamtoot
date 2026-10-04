#ifndef RUNNER_SITE_PREVIEW_H_
#define RUNNER_SITE_PREVIEW_H_
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
void site_preview_register(FlBinaryMessenger* messenger, GtkOverlay* overlay);
#endif
