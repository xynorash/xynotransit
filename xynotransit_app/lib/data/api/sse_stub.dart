import 'sse.dart';

/// No Server-Sent Events outside the browser: the app polls instead.
SseSource? createSseSource() => null;

PageVisibility createVisibility() => const AlwaysVisible();
