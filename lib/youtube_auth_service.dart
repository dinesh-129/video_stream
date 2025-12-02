// lib/services/youtube_auth_service.dart
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/youtube/v3.dart';
import 'package:http/http.dart' as http;

class YouTubeAuthService {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'https://www.googleapis.com/auth/userinfo.email',
      'https://www.googleapis.com/auth/youtube',
      'https://www.googleapis.com/auth/youtube.force-ssl',
    ],
    // Replace with your OAuth client ID (Web client ID often used for server auth)
    serverClientId: "246701892546-9j3knbobfdhhqli0prqvn6pqi7gs9qro.apps.googleusercontent.com",
  );

  GoogleSignInAccount? _currentUser;
  YouTubeApi? _youtubeApi;

  GoogleSignInAccount? get currentUser => _currentUser;

  Future<bool> signIn() async {
    try {
      final user = await _googleSignIn.signIn();
      if (user == null) return false;

      _currentUser = user;
      await _initYouTube();
      return true;
    } catch (e) {
      print("Login error: $e");
      return false;
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _currentUser = null;
    _youtubeApi = null;
  }

  Future<void> _initYouTube() async {
    final headers = await _currentUser!.authHeaders;
    final client = GoogleAuthClient(headers);
    _youtubeApi = YouTubeApi(client);
  }

  // 1. Get YouTube Channels of logged-in user
  Future<List<Channel>> getChannels() async {
    final response = await _youtubeApi!.channels.list(
      ['snippet', 'contentDetails'],
      mine: true,
    );
    return response.items ?? [];
  }

  // 2. Create YouTube Live Stream (RTMP Info)
  Future<LiveStream> createStream(String title) async {
    final ls = LiveStream(
      snippet: LiveStreamSnippet(title: title),
      cdn: CdnSettings(
        frameRate: "30fps",
        // resolution: "720p",
        resolution: "1080p",
        ingestionType: "rtmp",
      ),
    );

    final response = await _youtubeApi!.liveStreams.insert(ls, ['snippet', 'cdn']);
    return response;
  }

  // 3. Create Live Broadcast (event)
  // Future<LiveBroadcast> createBroadcast(String title) async {
  //   final now = DateTime.now().toUtc();

  //   final lb = LiveBroadcast(
  //     snippet: LiveBroadcastSnippet(
  //       title: title,
  //       scheduledStartTime: now,
  //     ),
  //     status: LiveBroadcastStatus(privacyStatus: "private"),
  //   );

  //   return await _youtubeApi!.liveBroadcasts.insert(lb, ['snippet', 'status']);
  // }

  Future<LiveBroadcast> createBroadcast(String title, {Duration scheduleIn = const Duration(seconds: 30)}) async {
  final nowUtc = DateTime.now().toUtc();
  final scheduled = nowUtc.add(scheduleIn);

  final lb = LiveBroadcast(
    snippet: LiveBroadcastSnippet(
      title: title,
      // scheduledStartTime expects an RFC3339 timestamp; the client library should handle DateTime,
      // but supplying a DateTime in UTC is safer.
      scheduledStartTime: scheduled,
    ),
    // choose unlisted/private depending on test; unlisted is often convenient for testing
    status: LiveBroadcastStatus(privacyStatus: "private"),
  );

  final response = await _youtubeApi!.liveBroadcasts.insert(lb, ['snippet', 'status']);
  print("createBroadcast: id=${response.id}, scheduled=${response.snippet?.scheduledStartTime}");
  return response;
}


  // 4. Bind broadcast + stream
  Future<LiveBroadcast> bind(String broadcastId, String streamId) async {
    final resp = await _youtubeApi!.liveBroadcasts.bind(
      broadcastId,
      ['id', 'snippet', 'status'],
      streamId: streamId,
    );
    return resp;
  }

  // 5. Check Stream Status
  Future<String?> getStreamStatus(String streamId) async {
    final response = await _youtubeApi!.liveStreams.list(
      ['status'],
      id: [streamId],
    );
    print(response.items?.first.status);
    print("YT streamStatus API returned: ${response.items?.first.status?.streamStatus}");

    if (response.items != null && response.items!.isNotEmpty) {
      return response.items!.first.status?.streamStatus;
    }
    return null;
  }

  // 6. Wait for Stream to be Active
  Future<bool> waitForStreamActive(String streamId, {int maxAttempts = 30}) async {
    for (int i = 0; i < maxAttempts; i++) {
      final status = await getStreamStatus(streamId);
      print("Stream status check $i: $status");
      if (status == "active") {
        return true;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  // 7. Transition - Go Live (testing -> live)
  // Future<void> goLive(String broadcastId) async {
  //   // Step 1: Transition to testing first
  //   await _youtubeApi!.liveBroadcasts.transition(
  //     "testing",
  //     broadcastId,
  //     ['status'],
  //   );
  //   // Wait a bit
  //   await Future.delayed(const Duration(seconds: 3));
  //   // Step 2: Transition to live
  //   await _youtubeApi!.liveBroadcasts.transition(
  //     "live",
  //     broadcastId,
  //     ['status'],
  //   );
  // }


  Future<void> goLive(String broadcastId) async {
  try {
    // transition to testing
    final testingResp = await _youtubeApi!.liveBroadcasts.transition(
      "testing",
      broadcastId,
      ['status'],
    );
    print("transition to testing: ${testingResp.status?.lifeCycleStatus}");

    // small wait & verify
    await Future.delayed(const Duration(seconds: 3));

    // transition to live
    final liveResp = await _youtubeApi!.liveBroadcasts.transition(
      "live",
      broadcastId,
      ['status'],
    );
    print("transition to live: ${liveResp.status?.lifeCycleStatus}");
  } catch (e) {
    print("goLive error: $e");
    rethrow;
  }
}


  Future<void> endBroadcast(String broadcastId) async {
  try {
    await _youtubeApi!.liveBroadcasts.transition(
      "complete",
      broadcastId,
      ['status'],
    );
    print("Broadcast $broadcastId ended.");
  } catch (e) {
    print("End broadcast error: $e");
  }
}

}

// Auth Client to attach auth headers to googleapis requests
class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest req) {
    req.headers.addAll(_headers);
    return _client.send(req);
  }
}
