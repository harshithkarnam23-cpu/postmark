import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  try {
    print('Searching for shorts...');
    var search = await yt.search.search('trending #shorts');
    for (var video in search.take(3)) {
      print('Found: ${video.title} (${video.duration})');
      var manifest = await yt.videos.streamsClient.getManifest(video.id);
      var streamInfo = manifest.muxed.withHighestBitrate();
      print('Stream URL: ${streamInfo.url}');
    }
  } catch (e) {
    print('Error: $e');
  } finally {
    yt.close();
  }
}
