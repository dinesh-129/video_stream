// lib/main.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:stream/youtube_auth_service.dart';

const SERVER =
    "http://192.168.1.23:5050"; // change to http://<PC_IP>:8080 on real device

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: StreamHome());
  }
}

class StreamHome extends StatefulWidget {
  const StreamHome({super.key});
  @override
  State<StreamHome> createState() => _StreamHomeState();
}

class _StreamHomeState extends State<StreamHome> {
  final YouTubeAuthService yt = YouTubeAuthService();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _streaming = false;
  List _channels = [];
  String? _selectedStreamKey;
  String? _broadcastId;
  String? _streamId;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _localStream?.getTracks().forEach((t) => t.stop());
    _pc?.close();
    super.dispose();
  }

  Future<void> signIn() async {
    final ok = await yt.signIn();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? "Signed in" : "Sign in failed")),
    );
  }

  Future<void> loadChannels() async {
    final channels = await yt.getChannels();
    setState(() => _channels = channels);
  }

  Future<void> createAndSendStream() async {
    try {
      // create liveStream + broadcast + bind
      final ls = await yt.createStream(
        "Mobile Stream ${DateTime.now().millisecondsSinceEpoch}",
      );
      final lb = await yt.createBroadcast(
        "Mobile Broadcast ${DateTime.now().millisecondsSinceEpoch}",
      );
      await yt.bind(lb.id!, ls.id!);

      // extract stream key (cdm.ingestionInfo.streamName)
      final key = ls.cdn?.ingestionInfo?.streamName;
      _streamId = ls.id;
      _broadcastId = lb.id;
      if (key == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not get stream key")),
        );
        return;
      }
      _selectedStreamKey = key;

      // send to Python server
      final res = await http.post(
        Uri.parse("$SERVER/set_stream_key"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'streamKey': key}),
      );
      if (res.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Stream key sent to server")),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Server error: ${res.body}")));
      }
    } catch (e) {
      print(e);
    }
  }

  // Future<void> startWebRTC() async {
  //   if (_selectedStreamKey == null) {
  //     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Create stream first")));
  //     return;
  //   }

  //   // get user media
  //   _localStream = await navigator.mediaDevices.getUserMedia({
  //     'audio': true,
  //     'video': {'facingMode': 'user'}
  //   });
  //   _localRenderer.srcObject = _localStream;

  //   // create peer connection
  //   _pc = await createPeerConnection({
  //     'iceServers': [
  //       {'urls': 'stun:stun.l.google.com:19302'}
  //     ]
  //   });

  //   _localStream!.getTracks().forEach((t) => _pc!.addTrack(t, _localStream!));

  //   final offer = await _pc!.createOffer();
  //   await _pc!.setLocalDescription(offer);

  //   final resp = await http.post(Uri.parse('$SERVER/offer'),
  //       headers: {'Content-Type': 'application/json'},
  //       body: jsonEncode({'sdp': offer.sdp, 'type': offer.type, 'rtmp': "rtmp://a.rtmp.youtube.com/live2/${_selectedStreamKey!}"}));

  //   if (resp.statusCode != 200) {
  //     ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Offer failed: ${resp.body}')));
  //     return;
  //   }

  //   final body = jsonDecode(resp.body);
  //   await _pc!.setRemoteDescription(RTCSessionDescription(body['sdp'], body['type']));
  //   setState(() => _streaming = true);
  // }

  String fixH264Profile(String sdp) {
    return sdp.replaceAll(
      "profile-level-id=42e01f",
      "profile-level-id=64001f", // HIGH profile
    );
  }

  String _preferH264(String sdp) {
    final lines = sdp.split('\r\n');
    final h264Payloads = <String>[];

    for (var line in lines) {
      if (line.startsWith("a=rtpmap:") && line.contains("H264")) {
        final payload = line.split(":")[1].split(" ")[0];
        h264Payloads.add(payload);
      }
    }

    final mLineIndex = lines.indexWhere((l) => l.startsWith("m=video"));
    if (mLineIndex == -1 || h264Payloads.isEmpty) return sdp;

    final parts = lines[mLineIndex].split(' ');
    final header = parts.sublist(0, 3);
    final payloads = parts.sublist(3);

    final newPayloads = [
      ...h264Payloads,
      ...payloads.where((p) => !h264Payloads.contains(p)),
    ];

    lines[mLineIndex] = [...header, ...newPayloads].join(' ');
    return lines.join('\r\n');
  }

  Future<void> initOverlaySocket() async {
    final token =
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJodHRwczovL3Nwb3J0c2FsLmNvbSIsImF1ZCI6IkFQUCIsImlhdCI6MTc2MzcwODc4MiwibmJmIjoxNzYzNzA4NzgyLCJleHAiOjE3NzE2NTc1ODIsInVzZXJJZCI6NDU3MywidXNlckNvZGUiOiJ1cy1UWmY3MlNXaW5rWEhrMkw4dEJtWkRaIiwidXNlclJvbGUiOiJQTEFZRVIifQ.oCyYwUoqdwP8BkC4CVDUzrR_VNEcGSKIvdHVUrk8TQw"; // ← from the scoring backend
    final roomcode = "MY_ROOM_CODE"; // ← same you use in old python
    final streamKey = _selectedStreamKey;
    final baseUrl = "http://13.203.156.75";
    // final baseUrl = "rtmp://a.rtmp.youtube.com/live2/$streamKey"; // scoring server base URL

    final res = await http.post(
      Uri.parse("$SERVER/init_overlay"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "token": token,
        "roomcode": roomcode,
        "baseUrl": baseUrl,
      }),
    );

    print("init_overlay => ${res.body}");
  }

  Future<void> startFullLiveProcess() async {
    try {
      // 1. Create the YouTube objects
      final ls = await yt.createStream(
        "Mobile Stream ${DateTime.now().millisecondsSinceEpoch}",
      );
      final lb = await yt.createBroadcast(
        "Mobile Broadcast ${DateTime.now().millisecondsSinceEpoch}",
        scheduleIn: Duration(seconds: 0),
      );
      // await yt.bind(lb.id!, ls.id!);
      final bindResp = await yt.bind(lb.id!, ls.id!);
      print(
        "bindResp: ${bindResp.id}, status=${bindResp.status?.lifeCycleStatus}",
      );

      _streamId = ls.id;
      _broadcastId = lb.id;

      final key = ls.cdn?.ingestionInfo?.streamName;
      if (key == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not get stream key")),
        );
        return;
      }

      _selectedStreamKey = key;

      // 2. Send key to python server
      final res = await http.post(
        Uri.parse("$SERVER/set_stream_key"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'streamKey': key}),
      );

      if (res.statusCode != 200) {
        print("Server rejected key");
        return;
      }

      // 3. Start WebRTC (start pushing video)
      await startWebRTC();

      // -------------------------------
      // 4. WAIT until YouTube sees video
      // -------------------------------
      print("Waiting for YouTube ingest...");
      // final ok = await yt.waitForStreamActive(_streamId!);

      // final ok = await yt.waitForStreamActive(_streamId!, maxAttempts: 90);
      final ok = await yt.waitForStreamActive(_streamId!, maxAttempts: 200);
      print("waitForStreamActive returned: $ok");

      if (!ok) {
        print("Stream never became active in YouTube!");
        return;
      }

      print("YouTube ingest ACTIVE!");

      // -------------------------------
      // 5. GO LIVE!
      // -------------------------------
      await yt.goLive(_broadcastId!);
      print("🎉 Broadcast is LIVE!");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Broadcast is LIVE!")));
    } catch (e) {
      print("Error: $e");
    }
  }

  Future<void> startWebRTC() async {
    final streamKey = _selectedStreamKey;
    if (streamKey == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Create Stream First")));
      return;
    }

    final rtmpUrl = "rtmp://a.rtmp.youtube.com/live2/$streamKey";

    _localStream = await navigator.mediaDevices.getUserMedia({
      "audio": true,
      "video": {
        "mandatory": {
          "minWidth": 1280,
          "minHeight": 720,
          "maxWidth": 1920,
          "maxHeight": 1080,
          "minFrameRate": 30,
          "maxFrameRate": 60,
        },
        "facingMode": "environment",
        // "width": {"ideal": 1280},
        // "height": {"ideal": 720},
        // "frameRate": {"ideal": 30},
      },
    });

    _localRenderer.srcObject = _localStream;

    _pc = await createPeerConnection({
      "iceServers": [
        {"urls": "stun:stun.l.google.com:19302"},
      ],
      "sdpSemantics": "unified-plan",
      "optional": [
        {"googCpuOveruseDetection": false},
        {"DtlsSrtpKeyAgreement": true},
        {"videoCodec": "H264"},
        {"videoMimeType": "video/H264"},
      ],
    });

    _localStream!.getTracks().forEach((t) {
      _pc!.addTrack(t, _localStream!);
    });

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    // final fixedSdp = _preferH264(offer.sdp!);
    final fixedSdp = fixH264Profile(_preferH264(offer.sdp!));

    final response = await http.post(
      Uri.parse("$SERVER/offer"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"sdp": fixedSdp, "type": offer.type, "rtmp": rtmpUrl}),
    );

    if (response.statusCode != 200) {
      print("Offer failed: ${response.body}");
      return;
    }

    final body = jsonDecode(response.body);
    await _pc!.setRemoteDescription(
      RTCSessionDescription(body["sdp"], body["type"]),
    );

    setState(() => _streaming = true);
  }

  // Future<void> stopAll() async {
  //   try {
  //     await http.post(Uri.parse('$SERVER/stop'));
  //   } catch (_) {}
  //   _localStream?.getTracks().forEach((t) => t.stop());
  //   _pc?.close();
  //   setState(() => _streaming = false);
  // }

  Future<void> stopAll() async {
    try {
      // Stop pushing to server
      await http.post(Uri.parse('$SERVER/stop'));

      // End previous YouTube broadcast if exists
      if (_broadcastId != null) {
        await yt.endBroadcast(_broadcastId!);
      }
    } catch (e) {
      print("Stop error: $e");
    }

    _localStream?.getTracks().forEach((t) => t.stop());
    _pc?.close();

    setState(() {
      _streaming = false;
      _selectedStreamKey = null;
      _broadcastId = null;
      _streamId = null;
    });
  }

  Widget channelList() {
    if (_channels.isEmpty) return const Text('No channels loaded');
    return SizedBox(
      height: 160,
      child: ListView.builder(
        itemCount: _channels.length,
        itemBuilder: (_, i) {
          final c = _channels[i];
          final title = c.snippet?.title ?? 'Unknown';
          return ListTile(
            title: Text(title),
            subtitle: Text('ID: ${c.id}'),
            onTap: () {
              // optionally select channel for UI only; stream creation uses account
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Channel selected (tap create stream to create broadcast/stream)',
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mobile → Python → YouTube')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Expanded(
              child: RTCVideoView(
                _localRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: signIn,
                  child: const Text('YouTube Sign-In'),
                ),
                ElevatedButton(
                  onPressed: loadChannels,
                  child: const Text('Load Channels'),
                ),
                // ElevatedButton(
                //   onPressed: createAndSendStream,
                //   child: const Text('Create Stream & Send Key'),
                // ),
                // ElevatedButton(onPressed: _streaming ? null : startWebRTC, child: const Text('Start Live')),

                // ElevatedButton(
                //   onPressed: _streaming ? null : startFullLiveProcess,
                //   child: const Text('Start Live'),
                // ),
                ElevatedButton(
                  onPressed: _streaming
                      ? null
                      : () async {
                          await initOverlaySocket(); // <-- REQUIRED
                          await startFullLiveProcess();
                        },
                  child: const Text('Start Live'),
                ),
                ElevatedButton(
                  onPressed: _streaming ? stopAll : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Stream Key: ${_selectedStreamKey ?? "not set"}',
              style: const TextStyle(fontSize: 12),
            ),

            Text(
              'broadcast Key: ${_broadcastId ?? "not set"}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            channelList(),
          ],
        ),
      ),
    );
  }
}
