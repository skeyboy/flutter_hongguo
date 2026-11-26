import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'main.dart' as app;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  runApp(const ProviderScope(child: UiVerifyHost(child: app.HongguoApp())));
}

class UiVerifyHost extends StatefulWidget {
  final Widget child;
  const UiVerifyHost({super.key, required this.child});

  @override
  State<UiVerifyHost> createState() => _UiVerifyHostState();
}

class _UiVerifyHostState extends State<UiVerifyHost> {
  HttpServer? _server;
  final _started = DateTime.now();
  final _boundaryKey = GlobalKey();
  static const _pointer = 17;
  static const _device = 3;

  Duration _stamp() => DateTime.now().difference(_started);

  BuildContext? _contextFor(Element element) {
    if (element is StatefulElement) return element.state.context;
    BuildContext? context;
    element.visitAncestorElements((ancestor) {
      if (ancestor is StatefulElement) {
        context = ancestor.state.context;
        return false;
      }
      return true;
    });
    return context;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 58999);
        debugPrint('UI_VERIFY_PORT=${_server!.port}');
        _server!.listen(_handle);
      } catch (error) {
        debugPrint('UI_VERIFY_BIND_FAILED=$error');
      }
    });
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _boundaryKey, child: widget.child);

  Future<void> _handle(HttpRequest request) async {
    try {
      final query = request.uri.queryParameters;
      final result = switch (request.uri.path) {
        '/state' => await _state(),
        '/tree' => _tree(),
        '/resize' => await _resize(query),
        '/tap' => await _tap(query),
        '/tapAt' => await _tapAt(query),
        '/back' => await _back(),
        '/shot' => await _shot(),
        '/hover' => await _hover(query),
        '/move' => await _move(query),
        '/text' => await _text(query),
        '/focus' => await _focus(query),
        '/key' => await _key(query),
        '/scroll' => await _scroll(query),
        _ => throw ArgumentError('unknown command'),
      };
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(result));
    } catch (error, stack) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': '$error', 'stack': '$stack'}));
    } finally {
      await request.response.close();
    }
  }

  Element? _findKey(String name) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      final key = element.widget.key;
      if (key == ValueKey(name) || key?.toString() == name) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  Future<Rect?> _rectFor(String name) async {
    final element = _findKey(name);
    if (element == null) return null;
    final context = _contextFor(element);
    if (context == null) return null;
    await Scrollable.ensureVisible(
      context,
      duration: Duration.zero,
      alignment: 0.5,
    );
    await WidgetsBinding.instance.endOfFrame;
    final object = element.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object.localToGlobal(Offset.zero) & object.size;
  }

  PointerEvent _pointerEvent(Offset position, {required bool down}) {
    final stamp = _stamp();
    if (down) {
      return PointerDownEvent(
        pointer: _pointer,
        device: _device,
        position: position,
        timeStamp: stamp,
        kind: PointerDeviceKind.mouse,
      );
    }
    return PointerUpEvent(
      pointer: _pointer,
      device: _device,
      position: position,
      timeStamp: stamp,
      kind: PointerDeviceKind.mouse,
    );
  }

  void _send(PointerEvent event) =>
      GestureBinding.instance.handlePointerEvent(event);

  Future<void> _moveTo(Offset position) async {
    _send(
      PointerHoverEvent(
        pointer: _pointer,
        device: _device,
        position: position,
        timeStamp: _stamp(),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<Map<String, Object?>> _resize(Map<String, String> query) async {
    final width = double.parse(query['width']!);
    final height = double.parse(query['height']!);
    await windowManager.setSize(Size(width, height));
    await windowManager.center();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await WidgetsBinding.instance.endOfFrame;
    return {'width': width, 'height': height};
  }

  Future<Map<String, Object?>> _tap(Map<String, String> query) async {
    final rect = await _rectFor(query['key']!);
    if (rect == null) throw StateError('key not found: ${query['key']}');
    final count = int.tryParse(query['count'] ?? '1') ?? 1;
    final point = rect.center;
    for (var index = 0; index < count; index++) {
      await _moveTo(point);
      _send(_pointerEvent(point, down: true));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      _send(_pointerEvent(point, down: false));
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    return {'rect': rect.toString()};
  }

  Future<Map<String, Object?>> _tapAt(Map<String, String> query) async {
    final point = Offset(
      double.parse(query['x'] ?? '0'),
      double.parse(query['y'] ?? '0'),
    );
    await _moveTo(point);
    _send(_pointerEvent(point, down: true));
    await Future<void>.delayed(const Duration(milliseconds: 70));
    _send(_pointerEvent(point, down: false));
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 70));
    return {'point': point.toString()};
  }

  Future<Map<String, Object?>> _back() async {
    NavigatorState? navigator;
    void visit(Element element) {
      if (element is StatefulElement && element.state is NavigatorState) {
        navigator = element.state as NavigatorState;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    if (navigator == null) throw StateError('navigator unavailable');
    final popped = await navigator!.maybePop();
    await WidgetsBinding.instance.endOfFrame;
    return {'popped': popped};
  }

  Future<Map<String, Object?>> _shot() async {
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('capture boundary unavailable');
    }
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('capture encoding failed');
    return {'png': base64Encode(data.buffer.asUint8List())};
  }

  Future<Map<String, Object?>> _hover(Map<String, String> query) async {
    final rect = await _rectFor(query['key']!);
    if (rect == null) throw StateError('key not found: ${query['key']}');
    await _moveTo(rect.center);
    await Future<void>.delayed(
      Duration(milliseconds: int.tryParse(query['wait'] ?? '0') ?? 0),
    );
    return {'rect': rect.toString()};
  }

  Future<Map<String, Object?>> _move(Map<String, String> query) async {
    await _moveTo(
      Offset(double.parse(query['x'] ?? '0'), double.parse(query['y'] ?? '0')),
    );
    return {'ok': true};
  }

  Future<Map<String, Object?>> _text(Map<String, String> query) async {
    final element = _findKey(query['key']!);
    if (element == null || element.widget is! TextField) {
      throw StateError('TextField not found: ${query['key']}');
    }
    final field = element.widget as TextField;
    final value = query['value'] ?? '';
    field.focusNode?.requestFocus();
    field.controller?.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    await WidgetsBinding.instance.endOfFrame;
    return {'text': value};
  }

  Future<Map<String, Object?>> _focus(Map<String, String> query) async {
    final element = _findKey(query['key']!);
    if (element == null) throw StateError('key not found: ${query['key']}');
    FocusNode? node;
    void visit(Element element) {
      if (node != null) return;
      final widget = element.widget;
      if (widget is Focus && widget.focusNode != null) {
        node = widget.focusNode;
        return;
      }
      element.visitChildren(visit);
    }

    visit(element);
    if (node == null) {
      FocusManager.instance.primaryFocus?.nextFocus();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await WidgetsBinding.instance.endOfFrame;
      return _state();
    }
    node!.requestFocus();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await WidgetsBinding.instance.endOfFrame;
    return {
      ...await _state(),
      'requestedKey': query['key'],
      'canRequestFocus': node!.canRequestFocus,
      'requestedHasFocus': node!.hasFocus,
    };
  }

  Future<Map<String, Object?>> _key(Map<String, String> query) async {
    final name = query['name'] ?? 'escape';
    final physical = switch (name) {
      'escape' => PhysicalKeyboardKey.escape,
      'backspace' => PhysicalKeyboardKey.backspace,
      'enter' => PhysicalKeyboardKey.enter,
      'space' => PhysicalKeyboardKey.space,
      'tab' => PhysicalKeyboardKey.tab,
      'arrowLeft' => PhysicalKeyboardKey.arrowLeft,
      'arrowRight' => PhysicalKeyboardKey.arrowRight,
      'arrowUp' => PhysicalKeyboardKey.arrowUp,
      'arrowDown' => PhysicalKeyboardKey.arrowDown,
      'keyL' => PhysicalKeyboardKey.keyL,
      'keyJ' => PhysicalKeyboardKey.keyJ,
      'keyM' => PhysicalKeyboardKey.keyM,
      'keyF' => PhysicalKeyboardKey.keyF,
      _ => throw ArgumentError('unknown key: $name'),
    };
    final logical = switch (name) {
      'escape' => LogicalKeyboardKey.escape,
      'backspace' => LogicalKeyboardKey.backspace,
      'enter' => LogicalKeyboardKey.enter,
      'space' => LogicalKeyboardKey.space,
      'tab' => LogicalKeyboardKey.tab,
      'arrowLeft' => LogicalKeyboardKey.arrowLeft,
      'arrowRight' => LogicalKeyboardKey.arrowRight,
      'arrowUp' => LogicalKeyboardKey.arrowUp,
      'arrowDown' => LogicalKeyboardKey.arrowDown,
      'keyL' => LogicalKeyboardKey.keyL,
      'keyJ' => LogicalKeyboardKey.keyJ,
      'keyM' => LogicalKeyboardKey.keyM,
      'keyF' => LogicalKeyboardKey.keyF,
      _ => throw ArgumentError('unknown key: $name'),
    };
    // ignore: deprecated_member_use
    final manager = ServicesBinding.instance.keyEventManager;
    // ignore: deprecated_member_use
    manager.handleKeyData(
      ui.KeyData(
        type: ui.KeyEventType.down,
        physical: physical.usbHidUsage,
        logical: logical.keyId,
        timeStamp: _stamp(),
        character: null,
        synthesized: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // ignore: deprecated_member_use
    manager.handleKeyData(
      ui.KeyData(
        type: ui.KeyEventType.up,
        physical: physical.usbHidUsage,
        logical: logical.keyId,
        timeStamp: _stamp(),
        character: null,
        synthesized: true,
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    return {'key': name, 'dispatched': true};
  }

  Future<Map<String, Object?>> _scroll(Map<String, String> query) async {
    final element = _findKey(query['key']!);
    final scrollable =
        element is StatefulElement && element.state is ScrollableState
        ? element.state as ScrollableState
        : null;
    if (scrollable == null) {
      throw StateError('Scrollable not found: ${query['key']}');
    }
    final position = scrollable.position;
    position.jumpTo(
      (position.pixels + double.parse(query['dy'] ?? '0')).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    return {'offset': position.pixels};
  }

  Future<Map<String, Object?>> _state() async {
    final fields = <Map<String, Object?>>[];
    void collectFields(Element element) {
      final widget = element.widget;
      if (widget is TextField) {
        fields.add({
          'key': widget.key?.toString(),
          'focused': widget.focusNode?.hasFocus ?? false,
        });
      }
      element.visitChildren(collectFields);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(collectFields);
    final focusedKeys = <String>[];
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext != null) {
      void collectFocus(Element element) {
        final key = element.widget.key;
        if (key is ValueKey<String>) focusedKeys.add(key.value);
        element.visitAncestorElements((ancestor) {
          final key = ancestor.widget.key;
          if (key is ValueKey<String>) focusedKeys.add(key.value);
          return true;
        });
      }

      collectFocus(focusedContext as Element);
    }
    final view = View.of(context);
    return {
      'window': {
        'width': view.physicalSize.width / view.devicePixelRatio,
        'height': view.physicalSize.height / view.devicePixelRatio,
      },
      'focus': FocusManager.instance.primaryFocus?.context?.widget.runtimeType
          .toString(),
      'focusedKeys': focusedKeys,
      'fields': fields,
    };
  }

  Map<String, Object?> _tree() {
    final items = <Map<String, Object?>>[];
    void visit(Element element) {
      final widget = element.widget;
      final key = widget.key;
      final interactive =
          widget is TextField ||
          widget is ButtonStyleButton ||
          widget is InkWell;
      if (interactive || (key != null && key is ValueKey<String>)) {
        final object = element.findRenderObject();
        final rect = object is RenderBox && object.attached && object.hasSize
            ? object.localToGlobal(Offset.zero) & object.size
            : null;
        String? tooltip;
        if (widget is IconButton) tooltip = widget.tooltip;
        if (widget is Tooltip) tooltip = widget.message;
        if (widget is TextField) tooltip = widget.key?.toString();
        items.add({
          'type': widget.runtimeType.toString(),
          'key': key?.toString(),
          'tooltip': tooltip,
          'enabled': widget is ButtonStyleButton
              ? widget.onPressed != null
              : widget is TextField
              ? widget.enabled
              : null,
          'rect': rect?.toString(),
        });
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return {'items': items};
  }
}
