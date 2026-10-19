import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'sse.dart';

/// Browser EventSource. Its own auto reconnect is switched off by closing on
/// the first error, because a ticket can only be used once.
SseSource? createSseSource() => _WebSseSource();

class _WebSseSource implements SseSource {
  @override
  Stream<SseEvent> open(Uri url) {
    late final StreamController<SseEvent> c;
    web.EventSource? es;
    c = StreamController<SseEvent>(
      onListen: () {
        final source = web.EventSource(url.toString());
        es = source;
        source.onopen = ((web.Event _) {
          if (!c.isClosed) c.add(const SseOpened());
        }).toJS;
        source.onmessage = ((web.MessageEvent e) {
          final d = e.data;
          if (!c.isClosed && d.isA<JSString>()) {
            c.add(SseMessage((d as JSString).toDart));
          }
        }).toJS;
        source.onerror = ((web.Event _) {
          source.close();
          if (!c.isClosed) {
            c.addError(StateError('Live connection lost'));
            unawaited(c.close());
          }
        }).toJS;
      },
      onCancel: () => es?.close(),
    );
    return c.stream;
  }
}

PageVisibility createVisibility() => _WebVisibility();

/// The page is hidden when its tab is in the background or the window is
/// minimised.
class _WebVisibility implements PageVisibility {
  @override
  bool get visible => web.document.visibilityState != 'hidden';

  @override
  Stream<bool> get changes {
    late final StreamController<bool> c;
    JSFunction? handler;
    c = StreamController<bool>.broadcast(
      onListen: () {
        handler = ((web.Event _) {
          if (!c.isClosed) c.add(visible);
        }).toJS;
        web.document.addEventListener('visibilitychange', handler);
      },
      onCancel: () {
        final h = handler;
        if (h != null) {
          web.document.removeEventListener('visibilitychange', h);
        }
      },
    );
    return c.stream;
  }
}
