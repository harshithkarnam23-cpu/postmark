import re

with open('lib/chat_page.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add import for audio_message_bubble
if "import 'package:postmark/widgets/audio_message_bubble.dart';" not in content:
    # Find last import
    imports = re.findall(r"^import\s+.*?;", content, re.MULTILINE)
    last_import = imports[-1] if imports else ""
    if last_import:
        content = content.replace(last_import, last_import + "\nimport 'package:postmark/widgets/audio_message_bubble.dart';\n")

# 2. Add media_audio to switch case
switch_pattern = r"case 'media_video':\s+return _buildMediaVideoCard\(docId, data, isMe\);"
if "case 'media_audio':" not in content:
    replacement_switch = """case 'media_video':
        return _buildMediaVideoCard(docId, data, isMe);
      case 'media_audio':
        return _buildMediaAudioCard(docId, data, isMe);"""
    content = content.replace("case 'media_video':\n        return _buildMediaVideoCard(docId, data, isMe);", replacement_switch)

# 3. Add _buildMediaAudioCard method
if "_buildMediaAudioCard" not in content:
    audio_card_code = """
  Widget _buildMediaAudioCard(String docId, Map<String, dynamic> data, bool isMe) {
    final fileName = data['fileName'] as String? ?? '';
    final cloudinaryUrl = data['cloudinary_url'] as String? ?? '';
    final uploadFailed = data['upload_failed'] == true;

    return FutureBuilder<String?>(
      future: _getLocalMediaFilePath(fileName),
      builder: (context, snapshot) {
        final localPath = snapshot.data;
        if (localPath == null && cloudinaryUrl.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isMe ? const Color(0xFF0A84FF) : const Color(0xFF2C2C2E),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text('Loading audio...', style: TextStyle(color: Colors.white70, fontSize: 13)),
          );
        }
        return AudioMessageBubble(
          audioUrl: cloudinaryUrl,
          localPath: localPath,
          isMe: isMe,
          isFile: localPath != null,
          timestamp: data['timestamp'],
          seen: data['seen'] == true,
        );
      },
    );
  }
"""
    # Insert it right before _buildMediaFileCard
    content = content.replace("Widget _buildMediaFileCard(", audio_card_code + "\n  Widget _buildMediaFileCard(")

# 4. Modify _buildMediaImageCard UI (solid bubble, remove glassmorphic)
# Current has:
image_container_pattern = r"""child: Container\(
\s*width: 200,
\s*height: 200,
\s*decoration: BoxDecoration\(
\s*borderRadius: BorderRadius\.circular\(18\),
\s*border: Border\.all\(color: Colors\.white\.withAlpha\(20\), width: 1\.0\),
\s*boxShadow: \[
\s*BoxShadow\(color: Colors\.black\.withAlpha\(60\), blurRadius: 8, offset: const Offset\(0, 4\)\),
\s*\],
\s*\),
\s*clipBehavior: Clip\.antiAlias,
\s*child: Hero\("""

new_image_container = """child: Container(
            constraints: const BoxConstraints(maxWidth: 250, maxHeight: 300),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Hero("""
content = re.sub(image_container_pattern, new_image_container, content)

# 5. Modify _buildMediaVideoCard
video_card_container_pattern = r"""return Container\(
\s*width: 200,
\s*height: 150,
\s*decoration: BoxDecoration\(
\s*color: const Color\(0xFF1C1C1E\)\.withAlpha\(180\), // Frosted translucent background
\s*borderRadius: BorderRadius\.circular\(18\),
\s*border: Border\.all\(color: Colors\.white\.withAlpha\(20\), width: 1\.0\), // Subtle outline border
\s*boxShadow: \[
\s*BoxShadow\(color: Colors\.black\.withAlpha\(80\), blurRadius: 10, offset: const Offset\(0, 4\)\),
\s*\],
\s*\),
\s*clipBehavior: Clip\.antiAlias,
\s*child: Stack\("""

# We want video to also have solid style and a thumbnail
new_video_container = """
        // Thumbnail URL from Cloudinary (change extension to .jpg)
        String thumbnailUrl = '';
        if (cloudinaryUrl.isNotEmpty) {
          final uri = Uri.parse(cloudinaryUrl);
          final pathSegments = uri.pathSegments;
          if (pathSegments.isNotEmpty) {
            final lastSegment = pathSegments.last;
            if (lastSegment.contains('.')) {
              final newSegment = lastSegment.split('.').first + '.jpg';
              thumbnailUrl = cloudinaryUrl.replaceFirst(lastSegment, newSegment);
            }
          }
        }

        return Container(
          constraints: const BoxConstraints(maxWidth: 250, maxHeight: 300),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack("""

content = re.sub(video_card_container_pattern, new_video_container, content)

# Replace the gray video_library gradient with the thumbnail
video_icon_bg_pattern = r"""Positioned\.fill\(
\s*child: Container\(
\s*decoration: const BoxDecoration\(
\s*gradient: LinearGradient\(
\s*colors: \[Color\(0xFF2C2C2E\), Color\(0xFF1C1C1E\)\],
\s*begin: Alignment\.topLeft,
\s*end: Alignment\.bottomRight,
\s*\),
\s*\),
\s*child: const Center\(
\s*child: Icon\(
\s*Icons\.video_library,
\s*color: Colors\.white24,
\s*size: 48,
\s*\),
\s*\),
\s*\),
\s*\),"""

new_video_bg = """Positioned.fill(
                child: thumbnailUrl.isNotEmpty
                    ? Image.network(thumbnailUrl, fit: BoxFit.cover)
                    : Container(
                        color: const Color(0xFF2C2C2E),
                        child: const Center(
                          child: Icon(Icons.video_library, color: Colors.white24, size: 48),
                        ),
                      ),
              ),"""

content = re.sub(video_icon_bg_pattern, new_video_bg, content)

with open('lib/chat_page.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print("Applied WhatsApp media UI changes!")
