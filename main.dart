import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

const port = 8080;
int nowUs() => DateTime.now().microsecondsSinceEpoch;

void main() => runApp(MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const Home(),
    ));

class Home extends StatelessWidget {
  const Home({super.key});
  void go(BuildContext c, bool host) =>
      Navigator.push(c, MaterialPageRoute(builder: (_) => Room(host: host)));
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Hotspot Music')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FilledButton(onPressed: () => go(c, true), child: const Text('Host — আমি গান চালাব')),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: () => go(c, false), child: const Text('Join — গান শুনব')),
          ]),
        ),
      );
}

class Room extends StatefulWidget {
  final bool host;
  const Room({super.key, required this.host});
  @override
  State<Room> createState() => _RoomState();
}

class _RoomState extends State<Room> {
  final player = AudioPlayer();
  final ipCtl = TextEditingController();
  final clients = <WebSocket>[];
  final ready = <WebSocket>{};
  HttpServer? server;
  WebSocket? ws;
  String? path, name;
  String status = '', hostIp = '';
  int offset = 0, best = 1 << 60; // hostTime = localTime + offset (microseconds)
  bool busy = false;
  bool get host => widget.host;

  void say(String s) {
    if (mounted) setState(() => status = s);
  }

  @override
  void initState() {
    super.initState();
    if (host) {
      startHost();
    } else {
      guessIp().then((v) => ipCtl.text = v);
    }
  }

  @override
  void dispose() {
    server?.close(force: true);
    ws?.close();
    player.dispose();
    super.dispose();
  }

  Future<List<String>> myIps() async {
    final l = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [for (final i in l) for (final a in i.addresses) a.address];
  }

  Future<String> guessIp() async {
    for (final a in await myIps()) {
      if (a.startsWith('192.168.')) return '${a.substring(0, a.lastIndexOf('.'))}.1';
    }
    return '192.168.43.1';
  }

  void send(Map m) {
    final s = jsonEncode(m);
    for (final c in clients) {
      try {
        c.add(s);
      } catch (_) {}
    }
  }

  Map fileMap() => {'t': 'file', 'name': name, 'size': File(path!).lengthSync()};

  // ---------------- HOST ----------------
  Future<void> startHost() async {
    server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    final ips = await myIps();
    say('হটস্পট অন রাখো। বন্ধুরা এই IP দিয়ে Join করবে: ${ips.join(', ')}');
    Timer.periodic(const Duration(seconds: 3), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (player.playing && !busy) {
        send({'t': 'sync', 'at': nowUs(), 'pos': player.position.inMilliseconds});
      }
    });
    server!.listen((req) async {
      final p = req.uri.path;
      if (p == '/ws') {
        final s = await WebSocketTransformer.upgrade(req);
        clients.add(s);
        if (path != null) s.add(jsonEncode(fileMap()));
        s.listen((raw) {
          final m = jsonDecode(raw as String) as Map;
          if (m['t'] == 'ping') {
            s.add(jsonEncode({'t': 'pong', 'c': m['c'], 'h': nowUs()}));
          } else if (m['t'] == 'ready') {
            if (mounted) {
              setState(() {
                ready.add(s);
              });
            }
          }
        }, onDone: () {
          clients.remove(s);
          if (mounted) {
            setState(() {
              ready.remove(s);
            });
          }
        });
        if (mounted) setState(() {});
      } else if (p == '/file' && path != null) {
        final f = File(path!);
        req.response.contentLength = await f.length();
        await req.response.addStream(f.openRead());
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  }

  Future<void> pick() async {
    final r = await FilePicker.platform.pickFiles();
    final f = r?.files.single;
    if (f?.path == null) return;
    hostPause();
    path = f!.path;
    name = f.name;
    ready.clear();
    await player.setFilePath(path!);
    say('ফাইল: $name — বন্ধুদের ফোনে যাচ্ছে');
    send(fileMap());
  }

  void hostPlay({int? pos, int wait = 4000}) {
    final p = pos ?? player.position.inMilliseconds;
    final at = nowUs() + wait * 1000;
    send({'t': 'play', 'at': at, 'pos': p});
    say('${wait ~/ 1000} সেকেন্ড পরে সবার ফোনে একসাথে শুরু হবে');
    startAt(at, p);
  }

  void hostPause() {
    player.pause();
    send({'t': 'pause'});
  }

  void jump(int s) {
    final p = player.position.inMilliseconds + s * 1000;
    hostPlay(pos: p < 0 ? 0 : p, wait: 3000);
  }

  // ---------------- CLIENT ----------------
  Future<void> join() async {
    hostIp = ipCtl.text.trim();
    say('কানেক্ট হচ্ছে...');
    try {
      ws = await WebSocket.connect('ws://$hostIp:$port/ws').timeout(const Duration(seconds: 6));
    } catch (e) {
      say('কানেক্ট হয়নি। IP ঠিক আছে? হটস্পটে কানেক্টেড আছ?');
      return;
    }
    ws!.listen(onMsg, onDone: () => say('হোস্টের সাথে কানেকশন কেটে গেছে'));
    say('কানেক্ট হয়েছে। হোস্টের গানের অপেক্ষা...');
    syncClock();
  }

  Future<void> syncClock() async {
    best = 1 << 60;
    for (var i = 0; i < 10; i++) {
      ws?.add(jsonEncode({'t': 'ping', 'c': nowUs()}));
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  void onMsg(dynamic raw) {
    final m = jsonDecode(raw as String) as Map;
    final t = m['t'];
    if (t == 'pong') {
      final c1 = nowUs();
      final rtt = c1 - (m['c'] as int);
      if (rtt < best) {
        best = rtt;
        offset = (m['h'] as int) + rtt ~/ 2 - c1;
      }
    } else if (t == 'file') {
      download(m['name'] as String, m['size'] as int);
    } else if (t == 'play') {
      syncClock();
      startAt(m['at'] as int, m['pos'] as int);
    } else if (t == 'pause') {
      player.pause();
    } else if (t == 'sync') {
      onSync(m);
    }
  }

  Future<void> download(String fname, int size) async {
    try {
      path = null;
      final ext = fname.contains('.') ? fname.substring(fname.lastIndexOf('.')) : '';
      final f = File('${Directory.systemTemp.path}/track${DateTime.now().millisecondsSinceEpoch}$ext');
      final req = await HttpClient().getUrl(Uri.parse('http://$hostIp:$port/file'));
      final res = await req.close();
      final sink = f.openWrite();
      var got = 0;
      await for (final c in res) {
        sink.add(c);
        got += c.length;
        say('ডাউনলোড হচ্ছে ${got * 100 ~/ (size == 0 ? 1 : size)}%');
      }
      await sink.close();
      await player.setFilePath(f.path);
      path = f.path;
      ws?.add(jsonEncode({'t': 'ready'}));
      say('তৈরি ✔ — হোস্টের প্লে চাপার অপেক্ষা');
    } catch (e) {
      say('ডাউনলোডে সমস্যা: $e');
    }
  }

  // দেরিতে জয়েন করলে বা সরে গেলে নিজে ঠিক করে নেয়
  Future<void> onSync(Map m) async {
    if (busy || path == null) return;
    final want = (m['pos'] as int) + (nowUs() + offset - (m['at'] as int)) ~/ 1000;
    if (!player.playing) {
      await player.seek(Duration(milliseconds: want));
      player.play();
    } else if ((player.position.inMilliseconds - want).abs() > 60) {
      await player.seek(Duration(milliseconds: want));
    }
  }

  // ---------------- SHARED: নির্দিষ্ট সময়ে একসাথে প্লে ----------------
  Future<void> startAt(int atHost, int posMs) async {
    if (path == null) return;
    busy = true;
    await player.pause();
    var left = atHost - offset - nowUs();
    await player.seek(Duration(milliseconds: posMs + (left < 0 ? -left ~/ 1000 : 0)));
    for (;;) {
      left = atHost - offset - nowUs();
      if (left <= 0) break;
      if (left > 40000) await Future.delayed(const Duration(milliseconds: 10));
    }
    player.play();
    busy = false;
  }

  @override
  Widget build(BuildContext c) {
    final ok = path != null;
    return Scaffold(
      appBar: AppBar(title: Text(host ? 'Host' : 'Join')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(status),
          const SizedBox(height: 16),
          if (host) ...[
            FilledButton(onPressed: pick, child: const Text('গান / ভিডিও বাছো')),
            const SizedBox(height: 8),
            Text('কানেক্টেড: ${clients.length}   তৈরি: ${ready.length}'),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(onPressed: ok ? () => jump(-10) : null, icon: const Icon(Icons.replay_10)),
              IconButton.filled(onPressed: ok ? hostPlay : null, icon: const Icon(Icons.play_arrow)),
              IconButton.filled(onPressed: ok ? hostPause : null, icon: const Icon(Icons.pause)),
              IconButton(onPressed: ok ? () => jump(10) : null, icon: const Icon(Icons.forward_10)),
            ]),
          ] else if (ws == null) ...[
            TextField(controller: ipCtl, decoration: const InputDecoration(labelText: 'হোস্টের IP')),
            const SizedBox(height: 8),
            FilledButton(onPressed: join, child: const Text('Connect')),
          ],
        ]),
      ),
    );
  }
}
