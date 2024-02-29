// Copyright 2022 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

///////////////////////////////////////////////////////////////////////////////
// 代码分两部分，一部分是 SimpleDatabase 客户端，一部分是 SimpleDatabase 服务端
///////////////////////////////////////////////////////////////////////////////

///////////////////////////////////////////////////////////////////////////////
// **WARNING:** This is not production code and is only intended to be used for
// demonstration purposes.
//
// The following database works by spawning a background isolate and
// communicating with it over Dart's SendPort API. It is presented below as a
// demonstration of the feature "Background Isolate Channels" and shows using
// plugins from a background isolate. The [SimpleDatabase] operates on the root
// isolate and the [_SimpleDatabaseServer] operates on a background isolate.
//
// Here is an example of the protocol they use to communicate:
// 这里介绍了 client 和 server 的通信流程。
// 1. 客户端是运行在主线程的，会创建一个 Isolate 启动后台 server 服务，并将自己的
//    receivePort.sendPort 传递过去，然后创建一个 Completer ，并等待其完成
// 2. server 端启动时会发一个 init 命令给 client ，并将自己的 receivePort.sendPort
//    传递给 client ，这样双方就可以通过对方的 receivePort.sendPort 进行通信
// 3. client 收到 server 的 init 命令，会回复一个 RootIsolateToken 过去
// 4. server 收到 RootIsolateToken ，会回复 ack
// 5. client 收到 ack， 会将之前创建的 Completer 标记为完成，结束等待，然后将 client
//    实例返回到主线程，以便主线程进行后续的操作
//
//  _________________                         ________________________
//  [:SimpleDatabase]                         [:_SimpleDatabaseServer]
//  -----------------                         ------------------------
//         |                                              |
//         |<---------------(init)------------------------|
//         |----------------(init)----------------------->|
//         |<---------------(ack)------------------------>|
//         |                                              |
//         |----------------(add)------------------------>|
//         |<---------------(ack)-------------------------|
//         |                                              |
//         |----------------(query)---------------------->|
//         |<---------------(result)----------------------|
//         |<---------------(result)----------------------|
//         |<---------------(done)------------------------|
//
///////////////////////////////////////////////////////////////////////////////

/// The size of the database entries in bytes.
const int _entrySize = 256;

/// All the command codes that can be sent and received between [SimpleDatabase] and
/// [_SimpleDatabaseServer].
enum _Codes {
  init,
  add,
  query,
  ack,
  result,
  done,
}

/// A command sent between [SimpleDatabase] and [_SimpleDatabaseServer].
class _Command {
  const _Command(this.code, {this.arg0, this.arg1});

  final _Codes code;
  final Object? arg0;
  final Object? arg1;
}

/// A SimpleDatabase that stores entries of strings to disk where they can be
/// queried.
///
/// All the disk operations and queries are executed in a background isolate
/// operating. This class just sends and receives messages to the isolate.
class SimpleDatabase {
  SimpleDatabase._(this._isolate, this._path);

  final Isolate _isolate;
  final String _path;
  late final SendPort _sendPort; //用来和 Isolate 交互
  // Completers are stored in a queue so multiple commands can be queued up and
  // handled serially.
  final Queue<Completer<void>> _completers = Queue<Completer<void>>();
  // Similarly, StreamControllers are stored in a queue so they can be handled
  // asynchronously and serially.
  final Queue<StreamController<String>> _resultsStream =
      Queue<StreamController<String>>();

  /// Open the database at [path] and launch the server on a background isolate..
  static Future<SimpleDatabase> open(String path) async {
    // 创建 reveivePort 用来接收响应
    final ReceivePort receivePort = ReceivePort();

    // 创建一个新的 Isolate ，注意这里第一个参数是 _SimpleDatabaseServer._run
    // 会在后台启动一个 Isolate ，执行的是 _SimpleDatabaseServer._run ，并将
    // receivedPort.sendPort 作为参数传递过去
    final Isolate isolate =
        await Isolate.spawn(_SimpleDatabaseServer._run, receivePort.sendPort);

    // 创建一个 SimpleDatabase 实例
    final SimpleDatabase result = SimpleDatabase._(isolate, path);

    //添加一个 Completer
    Completer<void> completer = Completer<void>();
    result._completers.addFirst(completer); //加入队列，后面处理会按先进先出的方式依次处理

    //添加监听事件处理
    receivePort.listen((message) {
      result._handleCommand(message as _Command);
    });

    //等待初始化完成
    await completer.future;
    return result;
  }

  /// Writes [value] to the database.
  Future<void> addEntry(String value) {
    // No processing happens on the calling isolate, it gets delegated to the
    // background isolate, see [__SimpleDatabaseServer._doAddEntry].
    Completer<void> completer = Completer<void>();
    _completers.addFirst(completer);
    _sendPort.send(_Command(_Codes.add, arg0: value));
    return completer.future;
  }

  /// Returns all the strings in the database that contain [query].
  Stream<String> find(String query) {
    // No processing happens on the calling isolate, it gets delegated to the
    // background isolate, see [__SimpleDatabaseServer._doFind].
    StreamController<String> resultsStream = StreamController<String>();
    _resultsStream.addFirst(resultsStream);
    _sendPort.send(_Command(_Codes.query, arg0: query));
    return resultsStream.stream;
  }

  /// Handler invoked when a message is received from the port communicating
  /// with the database server.
  void _handleCommand(_Command command) {
    switch (command.code) {
      case _Codes.init:
        _sendPort = command.arg0 as SendPort;
        // ----------------------------------------------------------------------
        // Before using platform channels and plugins from background isolates we
        // need to register it with its root isolate. This is achieved by
        // acquiring a [RootIsolateToken] which the background isolate uses to
        // invoke [BackgroundIsolateBinaryMessenger.ensureInitialized].
        // ----------------------------------------------------------------------
        RootIsolateToken rootIsolateToken = RootIsolateToken.instance!;
        //收到 server 的初始化响应后，回复 token 过去
        _sendPort
            .send(_Command(_Codes.init, arg0: _path, arg1: rootIsolateToken));
      case _Codes.ack:
        // 在 open 方法里面，添加了第一个 Completer<void> ,并 await complete.future
        // 那什么时候才会完成呢？就是在这里触发的完成。
        // 不止第一个，所有的 Completer 都是在这里标记的完成
        _completers.removeLast().complete();
      case _Codes.result:
        _resultsStream.last.add(command.arg0 as String);
      case _Codes.done:
        _resultsStream.removeLast().close();
      default:
        debugPrint('SimpleDatabase unrecognized command: ${command.code}');
    }
  }

  /// Kills the background isolate and its database server.
  void stop() {
    _isolate.kill();
  }
}

/// The portion of the [SimpleDatabase] that runs on the background isolate.
///
/// This is where we use the new feature Background Isolate Channels, which
/// allows us to use plugins from background isolates.
class _SimpleDatabaseServer {
  _SimpleDatabaseServer(this._sendPort);

  final SendPort _sendPort;
  late final String _path;

  // ----------------------------------------------------------------------
  // Here the plugin is used from the background isolate.
  // ----------------------------------------------------------------------

  /// The main entrypoint for the background isolate sent to [Isolate.spawn].
  /// sendPort 参数是客户端传递过来的
  static void _run(SendPort sendPort) {
    ReceivePort receivePort = ReceivePort();
    // 会先发一个初始化命令将 server 的 sendport 传递给客户端
    // 这样，client 和 server 都有了对方的 receivePort.sendPort
    // 就可以进行交流了
    sendPort.send(_Command(_Codes.init, arg0: receivePort.sendPort));
    final _SimpleDatabaseServer server = _SimpleDatabaseServer(sendPort);
    receivePort.listen((message) async {
      final _Command command = message as _Command;
      await server._handleCommand(command);
    });
  }

  /// Handle the [command] received from the [ReceivePort].
  Future<void> _handleCommand(_Command command) async {
    switch (command.code) {
      case _Codes.init:
        _path = command.arg0 as String;
        // ----------------------------------------------------------------------
        // The [RootIsolateToken] is required for
        // [BackgroundIsolateBinaryMessenger.ensureInitialized] and must be
        // obtained on the root isolate and passed into the background isolate via
        // a [SendPort].
        // ----------------------------------------------------------------------
        RootIsolateToken rootIsolateToken = command.arg1 as RootIsolateToken;
        // ----------------------------------------------------------------------
        // [BackgroundIsolateBinaryMessenger.ensureInitialized] for each
        // background isolate that will use plugins. This sets up the
        // [BinaryMessenger] that the Platform Channels will communicate with on
        // the background isolate.
        // ----------------------------------------------------------------------
        BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
        _sendPort.send(const _Command(_Codes.ack, arg0: null));
      case _Codes.add:
        _doAddEntry(command.arg0 as String);
      case _Codes.query:
        _doFind(command.arg0 as String);
      default:
        debugPrint(
            '_SimpleDatabaseServer unrecognized command ${command.code}');
    }
  }

  /// Perform the add entry operation.
  void _doAddEntry(String value) {
    debugPrint('Performing add: $value');
    File file = File(_path);
    if (!file.existsSync()) {
      file.createSync();
    }
    RandomAccessFile writer = file.openSync(mode: FileMode.append);
    List<int> bytes = utf8.encode(value);
    if (bytes.length > _entrySize) {
      bytes = bytes.sublist(0, _entrySize);
    } else if (bytes.length < _entrySize) {
      List<int> newBytes = List.filled(_entrySize, 0);
      for (int i = 0; i < bytes.length; ++i) {
        newBytes[i] = bytes[i];
      }
      bytes = newBytes;
    }
    writer.writeFromSync(bytes);
    writer.closeSync();
    _sendPort.send(const _Command(_Codes.ack, arg0: null));
  }

  /// Perform the find entry operation.
  void _doFind(String query) {
    debugPrint('Performing find: $query');
    File file = File(_path);
    if (file.existsSync()) {
      RandomAccessFile reader = file.openSync();
      List<int> buffer = List.filled(_entrySize, 0);
      while (reader.readIntoSync(buffer) == _entrySize) {
        List<int> foo = buffer.takeWhile((value) => value != 0).toList();
        String string = utf8.decode(foo);
        if (string.contains(query)) {
          _sendPort.send(_Command(_Codes.result, arg0: string));
        }
      }
      reader.closeSync();
    }
    _sendPort.send(const _Command(_Codes.done, arg0: null));
  }
}
