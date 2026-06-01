import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  try {
    var manifest = await yt.videos.streamsClient.getManifest('dQw4w9WgXcQ');
    var streamInfo = manifest.muxed.withHighestBitrate();
    print('Stream URL: ${streamInfo.url}');
  } catch (e) {
    print('Error: $e');
  } finally {
    yt.close();
  }
}
