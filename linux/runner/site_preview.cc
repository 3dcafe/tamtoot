#include "site_preview.h"
#include <map>
#include <cstring>
#ifdef TAMTOOT_WEBKIT
#include <webkit2/webkit2.h>
#endif

struct PreviewHost {
  GtkOverlay* overlay;
  std::map<int64_t, GtkWidget*> views;
};

static double number(FlValue* args, const char* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (!value) return 0;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(value);
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) return fl_value_get_int(value);
  return 0;
}

static void preview_call(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* host = static_cast<PreviewHost*>(data);
  const char* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    fl_method_call_respond_error(call, "arguments", "Expected preview arguments", nullptr, nullptr);
    return;
  }
  const int64_t id = static_cast<int64_t>(number(args, "id"));
  if (strcmp(method, "create") == 0) {
#ifdef TAMTOOT_WEBKIT
    FlValue* value = fl_value_lookup_string(args, "url");
    const char* url = value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
        ? fl_value_get_string(value) : nullptr;
    if (!url || !(g_str_has_prefix(url, "http://") || g_str_has_prefix(url, "https://"))) {
      fl_method_call_respond_error(call, "url", "Expected HTTP or HTTPS URL", nullptr, nullptr);
      return;
    }
    auto old = host->views.find(id);
    if (old != host->views.end()) gtk_widget_destroy(old->second);
    WebKitWebContext* context = webkit_web_context_new_ephemeral();
    GtkWidget* view = webkit_web_view_new_with_context(context);
    g_object_unref(context);
    gtk_widget_set_halign(view, GTK_ALIGN_START);
    gtk_widget_set_valign(view, GTK_ALIGN_START);
    gtk_widget_set_no_show_all(view, TRUE);
    gtk_overlay_add_overlay(host->overlay, view);
    host->views[id] = view;
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(view), url);
    fl_method_call_respond_success(call, nullptr, nullptr);
#else
    fl_method_call_respond_error(call, "webkit", "Build with WebKitGTK 4.1 development libraries installed", nullptr, nullptr);
#endif
    return;
  }
  const auto found = host->views.find(id);
  if (strcmp(method, "dispose") == 0) {
    if (found != host->views.end()) {
      gtk_widget_destroy(found->second);
      host->views.erase(found);
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "bounds") == 0) {
    if (found != host->views.end()) {
      GtkWidget* view = found->second;
      gtk_widget_set_margin_start(view, static_cast<int>(number(args, "x")));
      gtk_widget_set_margin_top(view, static_cast<int>(number(args, "y")));
      gtk_widget_set_size_request(view, static_cast<int>(number(args, "width")),
          static_cast<int>(number(args, "height")));
      FlValue* visible = fl_value_lookup_string(args, "visible");
      if (visible && fl_value_get_type(visible) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(visible)) {
        gtk_widget_show(view);
      } else {
        gtk_widget_hide(view);
      }
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

void site_preview_register(FlBinaryMessenger* messenger, GtkOverlay* overlay) {
  auto* host = new PreviewHost{overlay, {}};
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(messenger,
      "dev.tamtoot/site_preview", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, preview_call, host,
      [](gpointer data) { delete static_cast<PreviewHost*>(data); });
  g_object_set_data_full(G_OBJECT(overlay), "tamtoot-preview-channel", channel, g_object_unref);
}
