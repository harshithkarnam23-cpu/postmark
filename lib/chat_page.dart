import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'ably_service.dart';
import 'noto_emoji_data.dart';
import 'translation_service.dart';
import 'package:video_player/video_player.dart';
import 'ai_assistant_service.dart';
import 'cloudinary_service.dart';
import 'package:postmark/widgets/audio_message_bubble.dart';


class ChatPage extends StatefulWidget {
  final String currentUsername;
  final String targetUsername;
  final Color avatarColor;
  final String profilePictureUrl;
  final Color accentColor;
  final String? highlightMessageId;

  static final Map<String, String> drafts = {};

  const ChatPage({
    super.key,
    required this.currentUsername,
    required this.targetUsername,
    required this.avatarColor,
    required this.profilePictureUrl,
    required this.accentColor,
    this.highlightMessageId,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class MessageGroup {
  final String sender;
  final List<DocumentSnapshot> docs;

  MessageGroup({required this.sender, required this.docs});
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  static final List<String> _recentAnimatedEmojiCodes = [
    '1f600', '1f602', '1f60d', '1f923', '1f62d', '1f973', '1f3c0', '26bd'
  ];
  static final Set<String> _processedDownloadMessageIds = {};
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToBottomBtn = false;
  late final String _channelName;
  dynamic _ablyChannel;
  StreamSubscription? _ablySubscription;
  StreamSubscription<QuerySnapshot>? _targetUserSubscription;
  bool _isTargetOnline = false;
  final Map<String, Timer> _liveLocationTimers = {};

  // Real-time typing indicators
  bool _isTargetTyping = false;
  bool _isMeTyping = false;
  Timer? _typingTimer;

  // Smart auto scroll controls to prevent layout jumping
  bool _hasInitialScrolled = false;
  int _lastMessageCount = 0;

  // For message status reveal tap
  final Set<String> _visibleStatusIds = {};

  // For editing state
  final TextEditingController _editController = TextEditingController();

  // Premium chat options states
  bool _isSelectMode = false;
  final Set<String> _selectedMessageIds = {};
  int _disappearingDuration = 0; // 0 = off
  StreamSubscription? _chatDocSubscription;
  bool _isMuted = false;
  bool _isFavourited = false;
  bool _isBlocked = false;
  String _blockedBy = '';
  Map<String, dynamic>? _targetUserData;
  StreamSubscription? _relationshipSubscription;
  late final String _relationshipKey;

  // Starred message highlight redirection
  String? _highlightedMessageId;
  bool _hasScrolledToHighlight = false;
  final GlobalKey _highlightKey = GlobalKey();

  // AI & Mood Features
  String _selectedMood = 'Neutral';
  String _targetTranslationLanguage = 'English';
  Timer? _moodResetTimer;

  void _startMoodResetTimer() {
    _moodResetTimer?.cancel();
    _moodResetTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) {
        setState(() {
          _selectedMood = 'Neutral';
        });
      }
    });
  }

  Future<String?> _getLocalMediaFilePath(String fileName) async {
    try {
      Directory? targetDirectory;
      if (Platform.isWindows) {
        final docsDir = await getApplicationDocumentsDirectory();
        targetDirectory = Directory('${docsDir.path}/PostMark Media');
      } else if (Platform.isAndroid) {
        targetDirectory = Directory('/storage/emulated/0/Download/PostMark Media');
        if (!await targetDirectory.exists()) {
          targetDirectory = Directory('/storage/emulated/0/Documents/PostMark Media');
        }
        if (!await targetDirectory.exists()) {
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            targetDirectory = Directory('${externalDir.path}/PostMark Media');
          }
        }
      } else {
        final appDocDir = await getApplicationDocumentsDirectory();
        targetDirectory = Directory('${appDocDir.path}/PostMark Media');
      }

      final path = '${targetDirectory.path}/$fileName';
      if (await File(path).exists()) {
        return path;
      }
    } catch (_) {}
    return null;
  }

  void _checkAndTriggerDownloads(List<DocumentSnapshot> messages) {
    for (var doc in messages) {
      final data = doc.data() as Map<String, dynamic>;
      final msgType = data['type'] as String? ?? 'text';
      final docId = doc.id;

      if (msgType == 'media_image' || msgType == 'media_video' || msgType == 'media_file') {
        final cloudinaryUrl = data['cloudinary_url'] as String? ?? '';
        final cloudinaryPublicId = data['cloudinary_public_id'] as String? ?? '';
        final fileName = data['fileName'] as String? ?? '';
        final sender = data['sender'] as String? ?? '';
        final isCloudinaryDeleted = data['cloudinary_deleted'] as bool? ?? false;

        if (fileName.isEmpty) continue;

        if (_processedDownloadMessageIds.contains(docId)) continue;
        _processedDownloadMessageIds.add(docId);

        _getLocalMediaFilePath(fileName).then((localPath) async {
          if (localPath != null) {
            if (!isCloudinaryDeleted && sender.toLowerCase() != widget.currentUsername.toLowerCase() && cloudinaryPublicId.isNotEmpty) {
              final resourceType = msgType == 'media_image'
                  ? 'image'
                  : (msgType == 'media_video' ? 'video' : 'raw');
              final success = await CloudinaryService.destroyFile(
                publicId: cloudinaryPublicId,
                resourceType: resourceType,
              );
              if (success) {
                FirebaseFirestore.instance
                    .collection('chats')
                    .doc(_channelName)
                    .collection('messages')
                    .doc(docId)
                    .update({'cloudinary_deleted': true}).catchError((_) {});
              }
            }
            return;
          }

          if (isCloudinaryDeleted) return;

          if (cloudinaryUrl.isNotEmpty) {
            final downloadedPath = await CloudinaryService.saveFileToLocalFolder(cloudinaryUrl, fileName);
            if (downloadedPath != null) {
              if (mounted) {
                setState(() {});
              }

              if (sender.toLowerCase() != widget.currentUsername.toLowerCase() && cloudinaryPublicId.isNotEmpty) {
                final resourceType = msgType == 'media_image'
                    ? 'image'
                    : (msgType == 'media_video' ? 'video' : 'raw');
                final success = await CloudinaryService.destroyFile(
                  publicId: cloudinaryPublicId,
                  resourceType: resourceType,
                );
                if (success) {
                  FirebaseFirestore.instance
                      .collection('chats')
                      .doc(_channelName)
                      .collection('messages')
                      .doc(docId)
                      .update({'cloudinary_deleted': true}).catchError((_) {});
                }
              }
            }
          }
        });
      }
    }
  }

  
  void _sendLocationMessage(double lat, double lng, {bool isLive = false, String? liveDuration}) {
    DateTime? expiresAt;
    if (isLive && liveDuration != null) {
      final hours = int.tryParse(liveDuration.replaceFirst('h', '')) ?? 1;
      expiresAt = DateTime.now().add(Duration(hours: hours));
    }
    _sendCustomMessage(
      type: 'location',
      text: isLive ? '📍 Live Location Shared' : '📍 Location Shared',
      extraData: {
        'latitude': lat,
        'longitude': lng,
        'isLive': isLive,
        if (isLive) 'shareExpiresAt': expiresAt,
        if (isLive) 'liveDuration': liveDuration,
      },
    );
  }
Future<void> _sendCustomMessage({
    required String type,
    required String text,
    Map<String, dynamic>? extraData,
  }) async {
    HapticFeedback.lightImpact();
    final currentMood = _selectedMood;
    _startMoodResetTimer();

    final messageData = {
      'sender': widget.currentUsername,
      'text': text,
      'type': type,
      'timestamp': FieldValue.serverTimestamp(),
      'isEdited': false,
      'deletedForEveryone': false,
      'deletedFor': <String>[],
      'starredBy': <String>[],
      'seen': false,
      'mood': currentMood,
      if (_disappearingDuration > 0) 'disappearingDuration': _disappearingDuration,
      ...?extraData,
    };

    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .add(messageData);

      if (AblyService.instance.isInitialized && _ablyChannel != null) {
        await AblyService.instance.publishMessage(
          channel: _ablyChannel,
          sender: widget.currentUsername,
          text: 'custom_msg_type:$type||$text',
        );
      }

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .set({
        'lastMessage': text,
        'lastSender': widget.currentUsername,
        'lastTimestamp': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'participants': [
          widget.currentUsername.toLowerCase(),
          widget.targetUsername.toLowerCase()
        ],
      }, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('relationships')
          .doc(_relationshipKey)
          .update({
        'hiddenBy': FieldValue.arrayRemove([
          widget.currentUsername.toLowerCase(),
          widget.targetUsername.toLowerCase()
        ])
      }).catchError((_) {});

      _triggerSmartScroll(forceScroll: true);
    } catch (_) {}
  }

  Widget _buildCustomMessageCard(String docId, Map<String, dynamic> data, bool isMe) {
    final type = data['type'] as String? ?? 'text';
    switch (type) {
      case 'media_image':
        return _buildMediaImageCard(docId, data, isMe);
      case 'media_video':
        return _buildMediaVideoCard(docId, data, isMe);
      case 'media_audio':
        return _buildMediaAudioCard(docId, data, isMe);
      case 'media_file':
        return _buildMediaFileCard(docId, data, isMe);
      case 'location':
        return _buildLocationCard(docId, data, isMe);
      case 'poll':
        return _buildPollCard(docId, data, isMe);
      case 'event':
        return _buildEventCard(docId, data, isMe);
      default:
        return Text(data['text'] as String? ?? '', style: const TextStyle(color: Colors.white));
    }
  }

  Widget _buildMediaImageCard(String docId, Map<String, dynamic> data, bool isMe) {
    final fileName = data['fileName'] as String? ?? '';
    final cloudinaryDeleted = data['cloudinary_deleted'] as bool? ?? false;
    final cloudinaryUrl = data['cloudinary_url'] as String? ?? '';
    final uploadFailed = data['upload_failed'] == true;

    final timestamp = data['timestamp'];
    String formattedTime = 'Recent';
    if (timestamp != null) {
      try {
        if (timestamp is Timestamp) {
          formattedTime = DateFormat('h:mm a').format(timestamp.toDate().toLocal());
        } else if (timestamp is DateTime) {
          formattedTime = DateFormat('h:mm a').format(timestamp.toLocal());
        }
      } catch (_) {}
    }

    return FutureBuilder<String?>(
      future: _getLocalMediaFilePath(fileName),
      builder: (context, snapshot) {
        final localPath = snapshot.data;
        Widget imageWidget;

        if (localPath != null) {
          imageWidget = Stack(
            fit: StackFit.loose,
            children: [
              Image.file(
                File(localPath),
                fit: BoxFit.cover,
                errorBuilder: (c, e, s) => const Icon(Icons.broken_image, color: Colors.grey, size: 50),
              ),
              if (cloudinaryUrl.isEmpty && !uploadFailed)
                Positioned.fill(
                  child: Container(
                    color: Colors.black38,
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              if (uploadFailed)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Icon(Icons.error_outline, color: Color(0xFFFF453A), size: 30),
                    ),
                  ),
                ),
            ],
          );
        } else if (cloudinaryDeleted) {
          return _buildExpiredMediaPlaceholder('Photo clean-wiped from Cloud storage');
        } else if (cloudinaryUrl.isNotEmpty) {
          imageWidget = Image.network(
            cloudinaryUrl,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF)),
                ),
              );
            },
            errorBuilder: (c, e, s) => const Icon(Icons.broken_image, color: Colors.grey, size: 50),
          );
        } else if (uploadFailed) {
          return _buildExpiredMediaPlaceholder('Upload failed');
        } else {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E).withAlpha(180),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF)),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Sender is uploading photo...',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          );
        }

        // Beautiful Google Messages Overlay
        final beautifulImageWidget = Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: imageWidget,
            ),
            Positioned(
              bottom: 8,
              right: 8,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formattedTime,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Plus Jakarta Sans',
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        Icon(
                          data['seen'] == true ? Icons.done_all : Icons.done,
                          color: data['seen'] == true ? const Color(0xFF30D158) : Colors.white70,
                          size: 11,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );

        return GestureDetector(
          onTap: () {
            if (localPath != null) {
              if (cloudinaryUrl.isEmpty && !uploadFailed) {
                _showSuccessDialog(context, 'Uploading', 'This photo is being uploaded in the background.');
              } else {
                Navigator.push(
                  context,
                  PageRouteBuilder(
                    opaque: false,
                    barrierColor: Colors.black.withValues(alpha: 0.5),
                    transitionDuration: const Duration(milliseconds: 250),
                    reverseTransitionDuration: const Duration(milliseconds: 200),
                    pageBuilder: (context, animation, secondaryAnimation) => FullScreenImageViewer(
                      imagePath: localPath,
                      isFile: true,
                      sender: data['sender'] as String? ?? 'Unknown',
                      timestamp: data['timestamp'],
                      fileName: fileName,
                      heroTag: 'media_image_$docId',
                    ),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                  ),
                );
              }
            } else if (cloudinaryUrl.isNotEmpty) {
              Navigator.push(
                context,
                PageRouteBuilder(
                  opaque: false,
                  barrierColor: Colors.black.withValues(alpha: 0.5),
                  transitionDuration: const Duration(milliseconds: 250),
                  reverseTransitionDuration: const Duration(milliseconds: 200),
                  pageBuilder: (context, animation, secondaryAnimation) => FullScreenImageViewer(
                    imagePath: cloudinaryUrl,
                    isFile: false,
                    sender: data['sender'] as String? ?? 'Unknown',
                    timestamp: data['timestamp'],
                    fileName: fileName,
                    heroTag: 'media_image_$docId',
                  ),
                  transitionsBuilder: (context, animation, secondaryAnimation, child) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                ),
              );
            }
          },
          child: Container(
            constraints: const BoxConstraints(maxWidth: 250, maxHeight: 300),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Hero(
              tag: 'media_image_$docId',
              child: beautifulImageWidget,
            ),
          ),
        );
      },
    );
  }

  Widget _buildExpiredMediaPlaceholder(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: Color(0xFFFF453A), size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  // Replaced with top-level FullScreenImageViewer class

  Widget _buildMediaVideoCard(String docId, Map<String, dynamic> data, bool isMe) {
    final fileName = data['fileName'] as String? ?? '';
    final cloudinaryDeleted = data['cloudinary_deleted'] as bool? ?? false;
    final cloudinaryUrl = data['cloudinary_url'] as String? ?? '';
    final uploadFailed = data['upload_failed'] == true;

    final timestamp = data['timestamp'];
    String formattedTime = 'Recent';
    if (timestamp != null) {
      try {
        if (timestamp is Timestamp) {
          formattedTime = DateFormat('h:mm a').format(timestamp.toDate().toLocal());
        } else if (timestamp is DateTime) {
          formattedTime = DateFormat('h:mm a').format(timestamp.toLocal());
        }
      } catch (_) {}
    }

    return FutureBuilder<String?>(
      future: _getLocalMediaFilePath(fileName),
      builder: (context, snapshot) {
        final localPath = snapshot.data;

        String statusText;
        Color statusColor;
        IconData actionIcon;

        if (localPath != null) {
          if (cloudinaryUrl.isEmpty && !uploadFailed) {
            statusText = 'Uploading in background...';
            statusColor = const Color(0xFFFF9F0A);
            actionIcon = Icons.cloud_upload;
          } else if (uploadFailed) {
            statusText = 'Upload failed';
            statusColor = const Color(0xFFFF453A);
            actionIcon = Icons.error_outline;
          } else {
            statusText = 'Saved locally';
            statusColor = const Color(0xFF30D158);
            actionIcon = Icons.play_arrow;
          }
        } else {
          if (cloudinaryDeleted) {
            statusText = 'Expired';
            statusColor = const Color(0xFF8E8E93);
            actionIcon = Icons.cloud_off;
          } else if (cloudinaryUrl.isEmpty && !uploadFailed) {
            statusText = 'Sender is uploading...';
            statusColor = const Color(0xFFFF9F0A);
            actionIcon = Icons.hourglass_empty;
          } else if (uploadFailed) {
            statusText = 'Upload failed';
            statusColor = const Color(0xFFFF453A);
            actionIcon = Icons.error_outline;
          } else {
            statusText = 'Downloading...';
            statusColor = const Color(0xFFFF9F0A);
            actionIcon = Icons.download;
          }
        }

        
        // Thumbnail URL from Cloudinary (change extension to .jpg)
        String thumbnailUrl = '';
        if (cloudinaryUrl.isNotEmpty) {
          final uri = Uri.parse(cloudinaryUrl);
          final pathSegments = uri.pathSegments;
          if (pathSegments.isNotEmpty) {
            final lastSegment = pathSegments.last;
            if (lastSegment.contains('.')) {
              final newSegment = '${lastSegment.split('.').first}.jpg';
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
          child: Stack(
            children: [
              Positioned.fill(
                child: thumbnailUrl.isNotEmpty
                    ? Image.network(thumbnailUrl, fit: BoxFit.cover)
                    : Container(
                        color: const Color(0xFF2C2C2E),
                        child: const Center(
                          child: Icon(Icons.video_library, color: Colors.white24, size: 48),
                        ),
                      ),
              ),
              // Time and checkmark seen pill inside card
              Positioned(
                bottom: 8,
                right: 8,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    color: Colors.black.withValues(alpha: 0.55),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formattedTime,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Plus Jakarta Sans',
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          Icon(
                            data['seen'] == true ? Icons.done_all : Icons.done,
                            color: data['seen'] == true ? const Color(0xFF30D158) : Colors.white70,
                            size: 11,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              // Video status label at bottom left
              Positioned(
                bottom: 8,
                left: 8,
                right: 80,
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Plus Jakarta Sans',
                  ),
                ),
              ),
              // Play/Download/Status Icon Overlay
              Center(
                child: GestureDetector(
                  onTap: () {
                    if (localPath != null) {
                      if (cloudinaryUrl.isEmpty && !uploadFailed) {
                        _showSuccessDialog(context, 'Uploading', 'This video is being uploaded to Cloudinary in the background.');
                      } else {
                        Navigator.push(
                          context,
                          PageRouteBuilder(
                            opaque: false,
                            barrierColor: Colors.black.withValues(alpha: 0.5),
                            transitionDuration: const Duration(milliseconds: 250),
                            reverseTransitionDuration: const Duration(milliseconds: 200),
                            pageBuilder: (context, animation, secondaryAnimation) => FullScreenVideoViewer(
                              videoPath: localPath,
                              isFile: true,
                              sender: data['sender'] as String? ?? 'Unknown',
                              timestamp: data['timestamp'],
                              fileName: fileName,
                              heroTag: 'media_video_$docId',
                            ),
                            transitionsBuilder: (context, animation, secondaryAnimation, child) {
                              return FadeTransition(opacity: animation, child: child);
                            },
                          ),
                        );
                      }
                    } else if (cloudinaryDeleted) {
                      _showSuccessDialog(context, 'Media Expired', 'This video has already been deleted from Cloudinary storage to preserve limits.');
                    } else if (uploadFailed) {
                      _showSuccessDialog(context, 'Upload Failed', 'The background upload of this video failed.');
                    } else if (cloudinaryUrl.isEmpty) {
                      _showSuccessDialog(context, 'Uploading', 'The sender is still uploading this video.');
                    } else {
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          opaque: false,
                          barrierColor: Colors.black.withValues(alpha: 0.5),
                          transitionDuration: const Duration(milliseconds: 250),
                          reverseTransitionDuration: const Duration(milliseconds: 200),
                          pageBuilder: (context, animation, secondaryAnimation) => FullScreenVideoViewer(
                            videoPath: cloudinaryUrl,
                            isFile: false,
                            sender: data['sender'] as String? ?? 'Unknown',
                            timestamp: data['timestamp'],
                            fileName: fileName,
                            heroTag: 'media_video_$docId',
                          ),
                          transitionsBuilder: (context, animation, secondaryAnimation, child) {
                            return FadeTransition(opacity: animation, child: child);
                          },
                        ),
                      );
                    }
                  },
                  child: Hero(
                    tag: 'media_video_$docId',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(30),
                      child: Container(
                        width: 50,
                        height: 50,
                        color: Colors.black.withValues(alpha: 0.4),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: (cloudinaryUrl.isEmpty && !uploadFailed) ? const Color(0xFF2C2C2E) : const Color(0xFF0A84FF),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              actionIcon,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSuccessDialog(BuildContext context, String title, String text) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss Dialog',
      barrierColor: Colors.black.withAlpha(150),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.8,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Text(text, style: const TextStyle(color: Color(0xFFE5E5EA), fontSize: 14), textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(0xFF0A84FF),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('OK', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMediaAudioCard(String docId, Map<String, dynamic> data, bool isMe) {
    final fileName = data['fileName'] as String? ?? '';
    final cloudinaryUrl = data['cloudinary_url'] as String? ?? '';

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

  Widget _buildMediaFileCard(String docId, Map<String, dynamic> data, bool isMe) {
    final fileName = data['fileName'] as String? ?? '';
    final cloudinaryDeleted = data['cloudinary_deleted'] as bool? ?? false;
    final cloudinaryUrl = data['cloudinary_url'] as String? ?? '';
    final uploadFailed = data['upload_failed'] == true;
    final fileExtension = fileName.contains('.') ? fileName.split('.').last.toUpperCase() : 'FILE';

    final timestamp = data['timestamp'];
    String formattedTime = 'Recent';
    if (timestamp != null) {
      try {
        if (timestamp is Timestamp) {
          formattedTime = DateFormat('h:mm a').format(timestamp.toDate().toLocal());
        } else if (timestamp is DateTime) {
          formattedTime = DateFormat('h:mm a').format(timestamp.toLocal());
        }
      } catch (_) {}
    }

    return FutureBuilder<String?>(
      future: _getLocalMediaFilePath(fileName),
      builder: (context, snapshot) {
        final localPath = snapshot.data;

        String statusText;
        Color statusColor;
        IconData actionIcon;
        Color actionIconColor;

        if (localPath != null) {
          if (cloudinaryUrl.isEmpty && !uploadFailed) {
            statusText = 'Uploading...';
            statusColor = const Color(0xFFFF9F0A);
            actionIcon = Icons.cloud_upload;
            actionIconColor = const Color(0xFFFF9F0A);
          } else if (uploadFailed) {
            statusText = 'Upload failed';
            statusColor = const Color(0xFFFF453A);
            actionIcon = Icons.error_outline;
            actionIconColor = const Color(0xFFFF453A);
          } else {
            statusText = 'Saved Locally';
            statusColor = const Color(0xFF30D158);
            actionIcon = Icons.folder_open;
            actionIconColor = const Color(0xFF30D158);
          }
        } else {
          if (cloudinaryDeleted) {
            statusText = 'Expired';
            statusColor = const Color(0xFF8E8E93);
            actionIcon = Icons.cloud_off;
            actionIconColor = const Color(0xFF8E8E93);
          } else if (cloudinaryUrl.isEmpty && !uploadFailed) {
            statusText = 'Sender uploading...';
            statusColor = const Color(0xFFFF9F0A);
            actionIcon = Icons.hourglass_empty;
            actionIconColor = const Color(0xFFFF9F0A);
          } else if (uploadFailed) {
            statusText = 'Upload failed';
            statusColor = const Color(0xFFFF453A);
            actionIcon = Icons.error_outline;
            actionIconColor = const Color(0xFFFF453A);
          } else {
            statusText = 'Downloading...';
            statusColor = const Color(0xFFFF9F0A);
            actionIcon = Icons.download;
            actionIconColor = const Color(0xFFFF9F0A);
          }
        }

        return GestureDetector(
          onTap: () {
            final targetPath = localPath ?? (cloudinaryUrl.isNotEmpty ? cloudinaryUrl : null);
            final isFile = localPath != null;

            if (targetPath != null) {
              if (localPath != null && cloudinaryUrl.isEmpty && !uploadFailed) {
                _showSuccessDialog(context, 'Uploading', 'This document is being uploaded in the background.');
              } else {
                final lowerName = fileName.toLowerCase();
                if (lowerName.endsWith('.png') ||
                    lowerName.endsWith('.jpg') ||
                    lowerName.endsWith('.jpeg') ||
                    lowerName.endsWith('.gif') ||
                    lowerName.endsWith('.webp') ||
                    lowerName.endsWith('.bmp')) {
                  Navigator.push(
                    context,
                    PageRouteBuilder(
                      opaque: false,
                      barrierColor: Colors.black.withValues(alpha: 0.5),
                      transitionDuration: const Duration(milliseconds: 250),
                      reverseTransitionDuration: const Duration(milliseconds: 200),
                      pageBuilder: (context, animation, secondaryAnimation) => FullScreenImageViewer(
                        imagePath: targetPath,
                        isFile: isFile,
                        sender: data['sender'] as String? ?? 'Unknown',
                        timestamp: data['timestamp'],
                        fileName: fileName,
                        heroTag: 'media_file_$docId',
                      ),
                      transitionsBuilder: (context, animation, secondaryAnimation, child) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                    ),
                  );
                } else if (lowerName.endsWith('.mp4') ||
                    lowerName.endsWith('.mov') ||
                    lowerName.endsWith('.avi') ||
                    lowerName.endsWith('.mkv') ||
                    lowerName.endsWith('.3gp') ||
                    lowerName.endsWith('.webm')) {
                  Navigator.push(
                    context,
                    PageRouteBuilder(
                      opaque: false,
                      barrierColor: Colors.black.withValues(alpha: 0.5),
                      transitionDuration: const Duration(milliseconds: 250),
                      reverseTransitionDuration: const Duration(milliseconds: 200),
                      pageBuilder: (context, animation, secondaryAnimation) => FullScreenVideoViewer(
                        videoPath: targetPath,
                        isFile: isFile,
                        sender: data['sender'] as String? ?? 'Unknown',
                        timestamp: data['timestamp'],
                        fileName: fileName,
                        heroTag: 'media_file_$docId',
                      ),
                      transitionsBuilder: (context, animation, secondaryAnimation, child) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                    ),
                  );
                } else if (isFile && (
                    lowerName.endsWith('.txt') ||
                    lowerName.endsWith('.md') ||
                    lowerName.endsWith('.json') ||
                    lowerName.endsWith('.dart') ||
                    lowerName.endsWith('.js') ||
                    lowerName.endsWith('.py') ||
                    lowerName.endsWith('.csv') ||
                    lowerName.endsWith('.log') ||
                    lowerName.endsWith('.xml') ||
                    lowerName.endsWith('.yaml'))) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => FullScreenTextViewer(
                        filePath: targetPath,
                        sender: data['sender'] as String? ?? 'Unknown',
                        timestamp: data['timestamp'],
                        fileName: fileName,
                        heroTag: 'media_file_$docId',
                      ),
                    ),
                  );
                } else if (isFile) {
                  _openFileWithSystemDefault(context, targetPath, fileName);
                } else {
                  _showSuccessDialog(context, 'Downloading', 'Downloading file in the background...');
                }
              }
            } else if (cloudinaryDeleted) {
              _showSuccessDialog(context, 'File Expired', 'This file has already been destroyed from Cloudinary to maintain free limits.');
            } else if (uploadFailed) {
              _showSuccessDialog(context, 'Upload Failed', 'The background upload of this file failed.');
            } else {
              _showSuccessDialog(context, 'Downloading', 'Downloading file in the background...');
            }
          },
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.only(top: 12, left: 12, right: 12, bottom: 26),
            decoration: BoxDecoration(
              color: const Color(0xFF161618), // Google Messages sleek dark background
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withAlpha(20), width: 1.0), // Subtle outline border
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Row(
                  children: [
                    Hero(
                      tag: 'media_file_$docId',
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A84FF).withAlpha(40),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF0A84FF).withAlpha(120), width: 1),
                        ),
                        child: Center(
                          child: Text(
                            fileExtension,
                            style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 10, fontWeight: FontWeight.w900, fontFamily: 'Plus Jakarta Sans'),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'Plus Jakarta Sans'),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            statusText,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'Plus Jakarta Sans',
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      actionIcon,
                      color: actionIconColor,
                      size: 16,
                    ),
                  ],
                ),
                // Time & double check ticks at bottom right corner
                Positioned(
                  bottom: -20,
                  right: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formattedTime,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 9.5,
                          fontFamily: 'Plus Jakarta Sans',
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        Icon(
                          data['seen'] == true ? Icons.done_all : Icons.done,
                          color: data['seen'] == true ? const Color(0xFF30D158) : Colors.white60,
                          size: 11,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openFileWithSystemDefault(BuildContext context, String localPath, String fileName) async {
    try {
      final file = File(localPath);
      final exists = await file.exists();
      if (!context.mounted) return;
      if (exists) {
        final uri = Uri.file(localPath);
        final canLaunch = await canLaunchUrl(uri);
        if (!context.mounted) return;
        if (canLaunch) {
          await launchUrl(uri);
        } else {
          Clipboard.setData(ClipboardData(text: localPath));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Cannot open $fileName automatically. Path copied to clipboard!'),
              backgroundColor: const Color(0xFFEA4335),
            ),
          );
        }
      } else {
        _showSuccessDialog(context, 'File Not Found', 'The local file could not be found.');
      }
    } catch (e) {
      debugPrint('Error opening file: $e');
      if (!context.mounted) return;
      Clipboard.setData(ClipboardData(text: localPath));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening $fileName. Path copied to clipboard!'),
          backgroundColor: const Color(0xFFEA4335),
        ),
      );
    }
  }

  Widget _buildLocationCard(String docId, Map<String, dynamic> data, bool isMe) {
    final double latitude = (data['latitude'] as num? ?? 0.0).toDouble();
    final double longitude = (data['longitude'] as num? ?? 0.0).toDouble();
    final String address = data['address'] as String? ?? 'Shared Location';
    final bool isLive = data['isLive'] == true;
    final expiresAt = (data['shareExpiresAt'] as Timestamp?)?.toDate();
    final bool isExpired = expiresAt != null && DateTime.now().isAfter(expiresAt);
    final bool isLiveActive = isLive && !isExpired;

    if (isLiveActive && isMe && !_liveLocationTimers.containsKey(docId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_liveLocationTimers.containsKey(docId) && mounted) {
          _startLiveLocationTimer(docId, latitude, longitude);
        }
      });
    }

    String timeRemainingStr = '';
    if (isLive) {
      if (isExpired) {
        timeRemainingStr = 'Live ended';
      } else if (expiresAt != null) {
        final diff = expiresAt.difference(DateTime.now());
        if (diff.isNegative) {
          timeRemainingStr = 'Live ended';
        } else {
          final hours = diff.inHours;
          final mins = diff.inMinutes % 60;
          if (hours > 0) {
            timeRemainingStr = 'Live: ${hours}h ${mins}m left';
          } else {
            timeRemainingStr = 'Live: ${mins}m left';
          }
        }
      } else {
        timeRemainingStr = 'Live Location';
      }
    }

    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withAlpha(180),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withAlpha(20),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(60), blurRadius: 8, offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 90,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1E3A8A).withAlpha(100),
                  const Color(0xFF0F172A).withAlpha(100),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: MapMockupPainter(),
                  ),
                ),
                const Center(
                  child: Icon(Icons.location_on, color: Color(0xFFFF453A), size: 36),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (isLiveActive) ...[
                      const SizedBox(width: 4),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFF34A853),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
                if (isLive) ...[
                  const SizedBox(height: 2),
                  Text(
                    timeRemainingStr,
                    style: const TextStyle(
                      color: Color(0xFF8E8E93), 
                      fontSize: 11, 
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  '${latitude.toStringAsFixed(4)}°, ${longitude.toStringAsFixed(4)}°',
                  style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () async {
                                      Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => Scaffold(
                        appBar: AppBar(
                          title: const Text('Shared Location', style: TextStyle(color: Colors.white)),
                          backgroundColor: const Color(0xFF1E1F22),
                          iconTheme: const IconThemeData(color: Colors.white),
                        ),
                        body: GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target: LatLng(latitude, longitude),
                            zoom: 15.0,
                          ),
                          markers: {
                            Marker(
                              markerId: const MarkerId('shared_loc'),
                              position: LatLng(latitude, longitude),
                            ),
                          },
                        ),
                      ),
                    ),
                  );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF).withAlpha(40),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF0A84FF),
                      ),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.map, 
                          color: Color(0xFF0A84FF), 
                          size: 14,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Open in Maps',
                          style: TextStyle(
                            color: Color(0xFF0A84FF), 
                            fontSize: 12, 
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (isMe && isLiveActive) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () async {
                      try {
                        await FirebaseFirestore.instance
                            .collection('chats')
                            .doc(_channelName)
                            .collection('messages')
                            .doc(docId)
                            .update({'isLive': false});
                        _liveLocationTimers[docId]?.cancel();
                        _liveLocationTimers.remove(docId);
                      } catch (_) {}
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF453A).withAlpha(40),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFF453A)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.stop, color: Color(0xFFFF453A), size: 14),
                          SizedBox(width: 6),
                          Text(
                            'Stop Sharing',
                            style: TextStyle(color: Color(0xFFFF453A), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPollCard(String docId, Map<String, dynamic> data, bool isMe) {
    final question = data['pollQuestion'] as String? ?? 'Poll';
    final List<String> options = List<String>.from(data['pollOptions'] ?? []);
    final Map<String, dynamic> votes = Map<String, dynamic>.from(data['pollVotes'] ?? {});

    final totalVotes = votes.length;
    final Map<int, int> optionVotes = {};
    for (var val in votes.values) {
      final optIdx = (val as num).toInt();
      optionVotes[optIdx] = (optionVotes[optIdx] ?? 0) + 1;
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withAlpha(180), // Frosted translucent background
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(25), width: 1.0), // Elegant translucent border
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bar_chart, color: Color(0xFFBF5AF2), size: 18),
              const SizedBox(width: 6),
              const Text(
                'POLL',
                style: TextStyle(color: Color(0xFFBF5AF2), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            question,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ...List.generate(options.length, (index) {
            final optionText = options[index];
            final optVotesCount = optionVotes[index] ?? 0;
            final double percent = totalVotes > 0 ? optVotesCount / totalVotes : 0.0;
            final isVoted = votes[widget.currentUsername] == index;

            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: GestureDetector(
                onTap: () => _voteOnPoll(docId, votes, index),
                child: Stack(
                  children: [
                    Container(
                      height: 38,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2E),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isVoted ? const Color(0xFFBF5AF2) : Colors.transparent,
                          width: 1,
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: percent,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isVoted
                                ? const Color(0xFFBF5AF2).withAlpha(40)
                                : Colors.white.withAlpha(20),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      left: 12,
                      right: 12,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              optionText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isVoted ? const Color(0xFFBF5AF2) : Colors.white,
                                fontSize: 13,
                                fontWeight: isVoted ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ),
                          Text(
                            '${(percent * 100).toInt()}% ($optVotesCount)',
                            style: TextStyle(
                              color: isVoted ? const Color(0xFFBF5AF2) : const Color(0xFF8E8E93),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  void _voteOnPoll(String docId, Map<String, dynamic> currentVotes, int selectedIndex) {
    HapticFeedback.mediumImpact();
    final String myUser = widget.currentUsername;
    final updatedVotes = Map<String, dynamic>.from(currentVotes);
    
    if (updatedVotes[myUser] == selectedIndex) {
      updatedVotes.remove(myUser);
    } else {
      updatedVotes[myUser] = selectedIndex;
    }

    FirebaseFirestore.instance
        .collection('chats')
        .doc(_channelName)
        .collection('messages')
        .doc(docId)
        .update({'pollVotes': updatedVotes}).catchError((_) {});
  }

  Widget _buildEventCard(String docId, Map<String, dynamic> data, bool isMe) {
    final title = data['eventTitle'] as String? ?? 'Event';
    final dateTime = data['eventDateTime'] as String? ?? 'Date';
    final location = data['eventLocation'] as String? ?? '';
    final description = data['eventDescription'] as String? ?? '';
    final List<String> going = List<String>.from(data['eventGoing'] ?? []);

    final bool isGoing = going.contains(widget.currentUsername);

    String day = '29';
    String month = 'MAY';
    try {
      final parsed = DateTime.tryParse(dateTime) ?? DateTime.now();
      day = DateFormat('d').format(parsed);
      month = DateFormat('MMM').format(parsed).toUpperCase();
    } catch (_) {}

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withAlpha(180), // Frosted translucent background
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(25), width: 1.0), // Elegant translucent border
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 52, // Increased from 48 to 52 to resolve mobile font-height overflow
                decoration: BoxDecoration(
                  color: const Color(0xFFFF3B30).withAlpha(40),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFF3B30).withAlpha(80)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      month,
                      style: const TextStyle(
                        color: Color(0xFFFF3B30),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      day,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dateTime,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFFF9F0A), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (location.isNotEmpty || description.isNotEmpty) ...[
            const SizedBox(height: 12),
            if (description.isNotEmpty)
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFE5E5EA), fontSize: 12, height: 1.3),
              ),
            if (location.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.location_on, color: Color(0xFF8E8E93), size: 12),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      location,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
                    ),
                  ),
                ],
              ),
            ],
          ],
          // Attendees section showing who is going
          if (going.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              height: 1,
              color: Colors.white.withAlpha(20),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Row(
                  children: going.take(3).map((username) {
                    final int hash = username.codeUnits.fold(0, (prev, elem) => prev + elem);
                    final List<Color> colors = [
                      const Color(0xFFFF453A),
                      const Color(0xFF30D158),
                      const Color(0xFF0A84FF),
                      const Color(0xFFBF5AF2),
                      const Color(0xFFFF9F0A),
                    ];
                    final Color avatarColor = colors[hash % colors.length];
                    return Align(
                      widthFactor: 0.7,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF1C1C1E), width: 1.0),
                        ),
                        child: CircleAvatar(
                          radius: 10,
                          backgroundColor: avatarColor,
                          child: Text(
                            username.isNotEmpty ? username[0].toUpperCase() : '?',
                            style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                SizedBox(width: going.length > 3 ? 12 : 6),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      String attendeeText = '';
                      if (going.length == 1) {
                        final u = going.first;
                        if (u.toLowerCase() == widget.currentUsername.toLowerCase()) {
                          attendeeText = 'You are going';
                        } else {
                          attendeeText = '@${u.toLowerCase()} is going';
                        }
                      } else {
                        final otherUser = going.firstWhere(
                          (u) => u.toLowerCase() != widget.currentUsername.toLowerCase(),
                          orElse: () => '',
                        );
                        if (otherUser.isNotEmpty) {
                          attendeeText = 'You & @${otherUser.toLowerCase()} are going';
                        } else {
                          attendeeText = '${going.length} people going';
                        }
                      }
                      return Text(
                        attendeeText,
                        style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11, fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              final updatedGoing = List<String>.from(going);
              if (isGoing) {
                updatedGoing.remove(widget.currentUsername);
              } else {
                updatedGoing.add(widget.currentUsername);
              }
              FirebaseFirestore.instance
                  .collection('chats')
                  .doc(_channelName)
                  .collection('messages')
                  .doc(docId)
                  .update({'eventGoing': updatedGoing}).catchError((_) {});
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isGoing ? const Color(0xFF30D158).withAlpha(40) : const Color(0xFF0A84FF).withAlpha(40),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isGoing ? const Color(0xFF30D158) : const Color(0xFF0A84FF),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isGoing ? Icons.check_circle : Icons.event_available,
                    color: isGoing ? const Color(0xFF30D158) : const Color(0xFF0A84FF),
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      isGoing ? 'Going!' : 'RSVP: Going',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isGoing ? const Color(0xFF30D158) : const Color(0xFF0A84FF),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- BOTTOM OPTIONS SHEET & DIALOGS ---

  void _showAddOptionsSheet() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(120),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withAlpha(245), // Premium frosted dark gray
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withAlpha(20), width: 1.0),
          ),
          padding: const EdgeInsets.only(top: 16, left: 24, right: 24, bottom: 32),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Beautiful Handle Indicator
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(30),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Share Content',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 24),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 4,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.78,
                  children: [
                    _buildOptionItem(
                      label: 'Gallery',
                      icon: Icons.image,
                      color: const Color(0xFFEA4335), // Red
                      onTap: () {
                        Navigator.pop(context);
                        _pickAndSendMultipleMedia();
                      },
                    ),
                    _buildOptionItem(
                      label: 'Camera',
                      icon: Icons.videocam,
                      color: const Color(0xFFFBBC05), // Yellow
                      onTap: () {
                        Navigator.pop(context);
                        _showCameraOptionSelector();
                      },
                    ),
                    _buildOptionItem(
                      label: 'Files',
                      icon: Icons.insert_drive_file,
                      color: const Color(0xFF4285F4), // Blue
                      onTap: () {
                        Navigator.pop(context);
                        _pickAndSendFile();
                      },
                    ),
                    _buildOptionItem(
                      label: 'Location',
                      icon: Icons.location_on,
                      color: const Color(0xFF34A853), // Green
                      onTap: () {
                        Navigator.pop(context);
                        _showLocationTypeSelector();
                      },
                    ),
                    _buildOptionItem(
                      label: 'Poll',
                      icon: Icons.bar_chart,
                      color: const Color(0xFF9333EA), // Purple
                      onTap: () {
                        Navigator.pop(context);
                        _showCreatePollDialog();
                      },
                    ),
                    _buildOptionItem(
                      label: 'Event',
                      icon: Icons.event,
                      color: const Color(0xFF0D9488), // Teal
                      onTap: () {
                        Navigator.pop(context);
                        _showCreateEventDialog();
                      },
                    ),
                    _buildOptionItem(
                      label: 'Vault',
                      icon: Icons.folder_shared,
                      color: const Color(0xFFF59E0B), // Warm Amber
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const DeviceVaultPage(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildOptionItem({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color, // Solid backing color
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withAlpha(80),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 24), // White icon for solid background contrast
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFE3E3E3), fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  void _showLocationTypeSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(120),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withAlpha(245), // Premium frosted dark gray
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withAlpha(20), width: 1.0),
          ),
          padding: const EdgeInsets.only(top: 16, left: 24, right: 24, bottom: 32),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Beautiful Handle Indicator
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(30),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Share Location',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 20),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF34A853).withAlpha(35),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF34A853).withAlpha(100), width: 1.0),
                    ),
                    child: const Icon(Icons.my_location, color: Color(0xFF34A853), size: 20),
                  ),
                  title: const Text('Send Current Location', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: const Text('Share a static location marker', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11)),
                  onTap: () {
                    Navigator.pop(context);
                    _showShareLocationDialog(isLive: false);
                  },
                ),
                const Divider(color: Colors.white12, indent: 60),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4285F4).withAlpha(35),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF4285F4).withAlpha(100), width: 1.0),
                    ),
                    child: const Icon(Icons.people, color: Color(0xFF4285F4), size: 20),
                  ),
                  title: const Text('Share Live Location', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: const Text('Update your location in real-time', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11)),
                  onTap: () {
                    Navigator.pop(context);
                    _showLiveLocationDurationSelector();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showLiveLocationDurationSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(120),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withAlpha(245), // Premium frosted dark gray
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withAlpha(20), width: 1.0),
          ),
          padding: const EdgeInsets.only(top: 16, left: 24, right: 24, bottom: 32),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Beautiful Handle Indicator
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(30),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Share Live Location',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    'Participants in this chat will see your real-time location. You can stop sharing at any time.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBBC05).withAlpha(35),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFFBBC05).withAlpha(100), width: 1.0),
                    ),
                    child: const Icon(Icons.timer, color: Color(0xFFFBBC05), size: 20),
                  ),
                  title: const Text('Share for 1 Hour', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                  onTap: () {
                    Navigator.pop(context);
                    _showShareLocationDialog(isLive: true, liveDuration: '1h');
                  },
                ),
                const Divider(color: Colors.white12, indent: 60),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBBC05).withAlpha(35),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFFBBC05).withAlpha(100), width: 1.0),
                    ),
                    child: const Icon(Icons.hourglass_bottom, color: Color(0xFFFBBC05), size: 20),
                  ),
                  title: const Text('Share for 8 Hours', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                  onTap: () {
                    Navigator.pop(context);
                    _showShareLocationDialog(isLive: true, liveDuration: '8h');
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _startLiveLocationTimer(String docId, double initialLat, double initialLng) {
    _liveLocationTimers[docId]?.cancel();
    _liveLocationTimers[docId] = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!mounted) {
        timer.cancel();
        _liveLocationTimers.remove(docId);
        return;
      }
      try {
        final docRef = FirebaseFirestore.instance
            .collection('chats')
            .doc(_channelName)
            .collection('messages')
            .doc(docId);
        final docSnap = await docRef.get();
        if (!docSnap.exists) {
          timer.cancel();
          _liveLocationTimers.remove(docId);
          return;
        }
        final docData = docSnap.data();
        if (docData == null || docData['isLive'] != true) {
          timer.cancel();
          _liveLocationTimers.remove(docId);
          return;
        }
        final expiresAt = (docData['shareExpiresAt'] as Timestamp?)?.toDate();
        if (expiresAt == null || DateTime.now().isAfter(expiresAt)) {
          await docRef.update({'isLive': false});
          timer.cancel();
          _liveLocationTimers.remove(docId);
          return;
        }
        final double currentLat = (docData['latitude'] as num? ?? initialLat).toDouble();
        final double currentLng = (docData['longitude'] as num? ?? initialLng).toDouble();
        final random = Random();
        final double deltaLat = (random.nextDouble() - 0.5) * 0.00015;
        final double deltaLng = (random.nextDouble() - 0.5) * 0.00015;
        await docRef.update({
          'latitude': currentLat + deltaLat,
          'longitude': currentLng + deltaLng,
        });
      } catch (_) {}
    });
  }

  void _showUploadProgress(BuildContext context, String text) {
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withAlpha(160),
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF0A84FF)),
                ),
                const SizedBox(width: 16),
                Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, decoration: TextDecoration.none),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickAndSendMedia(ImageSource source, {required bool isVideo}) async {
    try {
      final picker = ImagePicker();
      final XFile? pickedFile = isVideo
          ? await picker.pickVideo(source: source)
          : await picker.pickImage(source: source, imageQuality: 85);

      if (pickedFile == null) return;

      final originalFile = File(pickedFile.path);
      final fileName = pickedFile.name;

      final localFilePath = await _savePickedFileToLocalFolder(originalFile, fileName);
      if (localFilePath == null) { debugPrint('Local save failed, continuing upload'); }

      final type = isVideo ? 'media_video' : 'media_image';
      final text = '[${isVideo ? "Video" : "Image"}] $fileName';

      HapticFeedback.lightImpact();
      final currentMood = _selectedMood;
      _startMoodResetTimer();

      final messageData = {
        'sender': widget.currentUsername,
        'text': text,
        'type': type,
        'timestamp': FieldValue.serverTimestamp(),
        'isEdited': false,
        'deletedForEveryone': false,
        'deletedFor': <String>[],
        'starredBy': <String>[],
        'seen': false,
        'mood': currentMood,
        if (_disappearingDuration > 0) 'disappearingDuration': _disappearingDuration,
        'cloudinary_url': '',
        'cloudinary_public_id': '',
        'fileName': fileName,
        'cloudinary_deleted': false,
        'upload_failed': false,
      };

      final docRef = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .add(messageData);

      _triggerSmartScroll(forceScroll: true);

      // Start upload in background
      _uploadMediaInBackground(docRef.id, originalFile, isVideo ? 'video' : 'image', type, text);
    } catch (_) {}
  }

  Future<void> _pickAndSendMultipleMedia() async {
    try {
      final List<File> filesToUpload = [];
      final List<String> fileNames = [];

      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final fp.FilePickerResult? result = await fp.FilePicker.pickFiles(
          allowMultiple: true,
          type: fp.FileType.media,
        );
        if (result != null && result.paths.isNotEmpty) {
          for (final path in result.paths) {
            if (path != null) {
              filesToUpload.add(File(path));
              fileNames.add(path.split(Platform.pathSeparator).last);
            }
          }
        }
      } else {
        final picker = ImagePicker();
        try {
          final List<XFile> pickedFiles = await picker.pickMultipleMedia();
          for (final pickedFile in pickedFiles) {
            filesToUpload.add(File(pickedFile.path));
            fileNames.add(pickedFile.name);
          }
        } catch (e) {
          final fp.FilePickerResult? result = await fp.FilePicker.pickFiles(
            allowMultiple: true,
            type: fp.FileType.media,
          );
          if (result != null && result.paths.isNotEmpty) {
            for (final path in result.paths) {
              if (path != null) {
                filesToUpload.add(File(path));
                fileNames.add(path.split('/').last);
              }
            }
          }
        }
      }

      if (filesToUpload.isEmpty) return;

      for (int i = 0; i < filesToUpload.length; i++) {
        final originalFile = filesToUpload[i];
        final fileName = fileNames[i];

        final localFilePath = await _savePickedFileToLocalFolder(originalFile, fileName);
        if (localFilePath == null) {
          debugPrint('Local save failed, continuing upload');
        }

        final lowerName = fileName.toLowerCase();
        final isVideo = lowerName.endsWith('.mp4') ||
            lowerName.endsWith('.mov') ||
            lowerName.endsWith('.avi') ||
            lowerName.endsWith('.mkv') ||
            lowerName.endsWith('.3gp') ||
            lowerName.endsWith('.webm');

        final type = isVideo ? 'media_video' : 'media_image';
        final text = '[${isVideo ? "Video" : "Image"}] $fileName';

        HapticFeedback.lightImpact();
        final currentMood = _selectedMood;
        _startMoodResetTimer();

        final messageData = {
          'sender': widget.currentUsername,
          'text': text,
          'type': type,
          'timestamp': FieldValue.serverTimestamp(),
          'isEdited': false,
          'deletedForEveryone': false,
          'deletedFor': <String>[],
          'starredBy': <String>[],
          'seen': false,
          'mood': currentMood,
          if (_disappearingDuration > 0) 'disappearingDuration': _disappearingDuration,
          'cloudinary_url': '',
          'cloudinary_public_id': '',
          'fileName': fileName,
          'cloudinary_deleted': false,
          'upload_failed': false,
        };

        final docRef = await FirebaseFirestore.instance
            .collection('chats')
            .doc(_channelName)
            .collection('messages')
            .add(messageData);

        _triggerSmartScroll(forceScroll: true);

        // Start upload in background
        _uploadMediaInBackground(docRef.id, originalFile, isVideo ? 'video' : 'image', type, text);
      }
    } catch (e) {
      debugPrint('Error picking multiple media: $e');
    }
  }

  Future<void> _pickAndSendFile() async {
    try {
      final fp.FilePickerResult? result = await fp.FilePicker.pickFiles(type: fp.FileType.any);
      if (result == null || result.files.single.path == null) return;

      final path = result.files.single.path!;
      final originalFile = File(path);
      final fileName = result.files.single.name;

      final localFilePath = await _savePickedFileToLocalFolder(originalFile, fileName);
      if (localFilePath == null) { debugPrint('Local save failed, continuing upload'); }

      String type = 'media_file';
      final ext = fileName.split('.').last.toLowerCase();
      if (['mp3', 'wav', 'm4a', 'ogg', 'aac'].contains(ext)) {
        type = 'media_audio';
      }
      final text = '[Document] $fileName';

      HapticFeedback.lightImpact();
      final currentMood = _selectedMood;
      _startMoodResetTimer();

      final messageData = {
        'sender': widget.currentUsername,
        'text': text,
        'type': type,
        'timestamp': FieldValue.serverTimestamp(),
        'isEdited': false,
        'deletedForEveryone': false,
        'deletedFor': <String>[],
        'starredBy': <String>[],
        'seen': false,
        'mood': currentMood,
        if (_disappearingDuration > 0) 'disappearingDuration': _disappearingDuration,
        'cloudinary_url': '',
        'cloudinary_public_id': '',
        'fileName': fileName,
        'cloudinary_deleted': false,
        'upload_failed': false,
      };

      final docRef = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .add(messageData);

      _triggerSmartScroll(forceScroll: true);

      // Start upload in background
      _uploadMediaInBackground(docRef.id, originalFile, 'raw', type, text);
    } catch (_) {}
  }

  Future<void> _uploadMediaInBackground(
    String messageId,
    File file,
    String resourceType,
    String msgType,
    String text,
  ) async {
    try {
      final uploadResult = await CloudinaryService.uploadFile(
        file: file,
        resourceType: resourceType,
      );

      if (uploadResult != null) {
        await FirebaseFirestore.instance
            .collection('chats')
            .doc(_channelName)
            .collection('messages')
            .doc(messageId)
            .update({
          'cloudinary_url': uploadResult['url'],
          'cloudinary_public_id': uploadResult['public_id'],
        });

        if (AblyService.instance.isInitialized && _ablyChannel != null) {
          await AblyService.instance.publishMessage(
            channel: _ablyChannel,
            sender: widget.currentUsername,
            text: 'custom_msg_type:$msgType||$text',
          ).catchError((_) {});
        }

        await FirebaseFirestore.instance
            .collection('chats')
            .doc(_channelName)
            .set({
          'lastMessage': text,
          'lastSender': widget.currentUsername,
          'lastTimestamp': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'participants': [
            widget.currentUsername.toLowerCase(),
            widget.targetUsername.toLowerCase()
          ],
        }, SetOptions(merge: true));
      } else {
        await FirebaseFirestore.instance
            .collection('chats')
            .doc(_channelName)
            .collection('messages')
            .doc(messageId)
            .update({
          'upload_failed': true,
        }).catchError((_) {});
      }
    } catch (_) {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .doc(messageId)
          .update({
        'upload_failed': true,
      }).catchError((_) {});
    }
  }

  Future<String?> _savePickedFileToLocalFolder(File originalFile, String fileName) async {
    try {
      Directory? targetDirectory;
      if (Platform.isWindows) {
        final docsDir = await getApplicationDocumentsDirectory();
        targetDirectory = Directory('${docsDir.path}/PostMark Media');
      } else if (Platform.isAndroid) {
        targetDirectory = Directory('/storage/emulated/0/Download/PostMark Media');
        if (!await targetDirectory.exists()) {
          targetDirectory = Directory('/storage/emulated/0/Documents/PostMark Media');
        }
        if (!await targetDirectory.exists()) {
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            targetDirectory = Directory('${externalDir.path}/PostMark Media');
          }
        }
      } else {
        final appDocDir = await getApplicationDocumentsDirectory();
        targetDirectory = Directory('${appDocDir.path}/PostMark Media');
      }

      if (!await targetDirectory.exists()) {
        await targetDirectory.create(recursive: true);
      }

      final localFilePath = '${targetDirectory.path}/$fileName';
      final localFile = File(localFilePath);
      
      await localFile.writeAsBytes(await originalFile.readAsBytes());
      return localFilePath;
    } catch (_) {
      return null;
    }
  }

  Future<void> _showShareLocationDialog({bool isLive = false, String? liveDuration}) async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location services are disabled.')));
      }
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permissions are denied')));
        }
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permissions are permanently denied, we cannot request permissions.')));
      }
      return;
    } 

    if (mounted) {
      _showUploadProgress(context, 'Fetching Location...');
    }
    Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    if (mounted) {
      Navigator.of(context).pop();
    }
    
    _sendLocationMessage(position.latitude, position.longitude, isLive: isLive, liveDuration: liveDuration);

  }


  void _showCreatePollDialog() {
    final TextEditingController questionC = TextEditingController();
    final List<TextEditingController> optionControllers = [
      TextEditingController(),
      TextEditingController(),
    ];

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss Dialog',
      barrierColor: Colors.black.withAlpha(160),
      pageBuilder: (context, anim1, anim2) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Center(
              child: SingleChildScrollView(
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.85,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Create Poll',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        _buildDialogTextField('Question / Topic', questionC),
                        const SizedBox(height: 16),
                        const Text('POLL OPTIONS', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 10, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ...List.generate(optionControllers.length, (index) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: _buildDialogTextField('Option ${index + 1}', optionControllers[index]),
                                ),
                                if (optionControllers.length > 2) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle, color: Color(0xFFFF453A)),
                                    onPressed: () {
                                      setDialogState(() {
                                        optionControllers.removeAt(index);
                                      });
                                    },
                                  ),
                                ],
                              ],
                            ),
                          );
                        }),
                        if (optionControllers.length < 5) ...[
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: () {
                              setDialogState(() {
                                optionControllers.add(TextEditingController());
                              });
                            },
                            child: const Row(
                              children: [
                                Icon(Icons.add_circle, color: Color(0xFFBF5AF2), size: 16),
                                SizedBox(width: 6),
                                Text('Add Option', style: TextStyle(color: Color(0xFFBF5AF2), fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                            ),
                            const SizedBox(width: 12),
                            TextButton(
                              onPressed: () {
                                final question = questionC.text.trim();
                                if (question.isEmpty) return;

                                final List<String> options = [];
                                for (var c in optionControllers) {
                                  final opt = c.text.trim();
                                  if (opt.isNotEmpty) options.add(opt);
                                }

                                if (options.length < 2) return;

                                Navigator.pop(context);
                                _sendCustomMessage(
                                  type: 'poll',
                                  text: '[Poll] $question',
                                  extraData: {
                                    'pollQuestion': question,
                                    'pollOptions': options,
                                    'pollVotes': <String, int>{},
                                  },
                                );
                              },
                              style: TextButton.styleFrom(
                                backgroundColor: const Color(0xFFBF5AF2),
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              child: const Text('Create', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showCreateEventDialog() {
    final TextEditingController titleC = TextEditingController();
    final TextEditingController dateC = TextEditingController(text: DateTime.now().add(const Duration(days: 1)).toString().substring(0, 16));
    final TextEditingController locationC = TextEditingController();
    final TextEditingController descC = TextEditingController();

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss Dialog',
      barrierColor: Colors.black.withAlpha(160),
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: SingleChildScrollView(
            child: Container(
              width: MediaQuery.of(context).size.width * 0.85,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Create Event',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    _buildDialogTextField('Event Title', titleC),
                    const SizedBox(height: 12),
                    _buildDialogTextField('Date & Time (YYYY-MM-DD HH:MM)', dateC),
                    const SizedBox(height: 12),
                    _buildDialogTextField('Venue / Location', locationC),
                    const SizedBox(height: 12),
                    _buildDialogTextField('Event Description', descC, maxLines: 2),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: () {
                            final title = titleC.text.trim();
                            final date = dateC.text.trim();
                            if (title.isEmpty || date.isEmpty) return;

                            Navigator.pop(context);
                            _sendCustomMessage(
                              type: 'event',
                              text: '[Event] $title - $date',
                              extraData: {
                                'eventTitle': title,
                                'eventDateTime': date,
                                'eventLocation': locationC.text.trim(),
                                'eventDescription': descC.text.trim(),
                                'eventGoing': <String>[],
                              },
                            );
                          },
                          style: TextButton.styleFrom(
                            backgroundColor: const Color(0xFFFF375F),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Create', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDialogTextField(
    String hint,
    TextEditingController controller, {
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateOnlineStatus(true);
    _loadRecentEmojis();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _precacheEmojis();
    });
    _channelName = AblyService.instance.getChatChannelName(
      widget.currentUsername,
      widget.targetUsername,
    );

    // Load target translation language preference from Firestore
    FirebaseFirestore.instance
        .collection('userdetails')
        .where('username', isEqualTo: widget.currentUsername)
        .get()
        .then((snap) {
      if (snap.docs.isNotEmpty && mounted) {
        setState(() {
          _targetTranslationLanguage = snap.docs.first.data()['selectedLanguage'] as String? ?? 'English';
        });
      }
    });

    final sorted = [widget.currentUsername.toLowerCase(), widget.targetUsername.toLowerCase()]..sort();
    _relationshipKey = '${sorted[0]}_${sorted[1]}';

    // Load any existing draft
    final draftText = ChatPage.drafts[widget.targetUsername.toLowerCase()];
    if (draftText != null && draftText.isNotEmpty) {
      _messageController.text = draftText;
    }

    // Initialize highlight for starred message redirection
    if (widget.highlightMessageId != null) {
      _highlightedMessageId = widget.highlightMessageId;
      _visibleStatusIds.add(widget.highlightMessageId!);
      // Fade out the highlight after 3 seconds
      Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _highlightedMessageId = null;
          });
        }
      });
    }

    // Subscribe to chat doc for disappearing messages duration
    _chatDocSubscription = FirebaseFirestore.instance
        .collection('chats')
        .doc(_channelName)
        .snapshots()
        .listen((snap) {
      if (snap.exists && mounted) {
        final data = snap.data();
        setState(() {
          _disappearingDuration = data?['disappearingDuration'] as int? ?? 0;
        });
      }
    });

    // Subscribe to relationship doc for mute and favourite statuses
    _relationshipSubscription = FirebaseFirestore.instance
        .collection('relationships')
        .doc(_relationshipKey)
        .snapshots()
        .listen((snap) {
      if (snap.exists && mounted) {
        final data = snap.data();
        final mutedBy = List<String>.from(data?['mutedBy'] ?? []);
        final favouritedBy = List<String>.from(data?['favouritedBy'] ?? []);
        final status = data?['status'] as String? ?? '';
        final blockedBy = data?['blockedBy'] as String? ?? '';
        setState(() {
          _isMuted = mutedBy.contains(widget.currentUsername);
          _isFavourited = favouritedBy.contains(widget.currentUsername);
          _isBlocked = status == 'blocked';
          _blockedBy = blockedBy;
        });
      }
    });

    // Initialize Ably connection if active
    if (AblyService.instance.isInitialized) {
      try {
        _ablyChannel = AblyService.instance.getChatChannel(
          widget.currentUsername,
          widget.targetUsername,
        );

        // Listen to all Ably channel events (messages + typing events)
        _ablySubscription = _ablyChannel.subscribe().listen((message) {
          final name = message.name;
          final data = message.data;
          if (name == 'typing' && data is Map) {
            final sender = data['sender'] as String? ?? '';
            final typing = data['typing'] as bool? ?? false;
            if (sender.toLowerCase() == widget.targetUsername.toLowerCase()) {
              if (mounted) {
                setState(() {
                  _isTargetTyping = typing;
                });
                // Auto scroll slightly if typing indicator shows up
                _triggerSmartScroll(forceScroll: true);
              }
            }
          } else if (name == 'message' && data is Map) {
            final text = data['text'] as String? ?? '';
            if (!text.startsWith('reaction_update:')) {
              _triggerSmartScroll(forceScroll: true);
            }
          }
        });
      } catch (e) {
        _ablyChannel = null;
        debugPrint("Ably subscription failed: $e");
      }
    }

    // Monitor target user's online status in real-time
    _targetUserSubscription = FirebaseFirestore.instance
        .collection('userdetails')
        .where('username', isEqualTo: widget.targetUsername)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.docs.isNotEmpty) {
        final data = snapshot.docs.first.data() as Map<String, dynamic>?;
        final online = data?['isOnline'] as bool? ?? false;
        if (mounted) {
          setState(() {
            _isTargetOnline = online;
            _targetUserData = data;
          });
        }
      }
    });

    // Monitor message input to publish real-time typing events (Snapchat/Instagram style) and save drafts
    _messageController.addListener(() {
      final text = _messageController.text;
      if (text.isNotEmpty) {
        ChatPage.drafts[widget.targetUsername.toLowerCase()] = text;
        if (!_isMeTyping) {
          _isMeTyping = true;
          _sendTypingEvent(true);
        }
      } else {
        ChatPage.drafts.remove(widget.targetUsername.toLowerCase());
        if (_isMeTyping) {
          _isMeTyping = false;
          _sendTypingEvent(false);
        }
      }
      
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(seconds: 2), () {
        if (_isMeTyping) {
          _isMeTyping = false;
          _sendTypingEvent(false);
        }
      });
    });

    _scrollController.addListener(() {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      final showBtn = (maxScroll - currentScroll) > 300;
      if (showBtn != _showScrollToBottomBtn) {
        setState(() {
          _showScrollToBottomBtn = showBtn;
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _editController.dispose();
    _scrollController.dispose();
    _ablySubscription?.cancel();
    _targetUserSubscription?.cancel();
    _chatDocSubscription?.cancel();
    _relationshipSubscription?.cancel();
    _typingTimer?.cancel();
    _moodResetTimer?.cancel();
    for (final timer in _liveLocationTimers.values) {
      timer.cancel();
    }
    _liveLocationTimers.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updateOnlineStatus(true);
    } else {
      _updateOnlineStatus(false);
    }
  }

  Future<void> _updateOnlineStatus(bool isOnline) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('userdetails')
          .where('username', isEqualTo: widget.currentUsername)
          .limit(1)
          .get();
      if (snapshot.docs.isNotEmpty) {
        await snapshot.docs.first.reference.update({'isOnline': isOnline});
      }
    } catch (_) {}
  }

  // Publish typing status to Ably
  Future<void> _sendTypingEvent(bool typing) async {
    try {
      if (AblyService.instance.isInitialized && _ablyChannel != null) {
        await _ablyChannel.publish(
          name: 'typing',
          data: {'sender': widget.currentUsername, 'typing': typing},
        );
      }
    } catch (_) {}
  }

  void _triggerSmartScroll({bool forceScroll = false}) {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;

      if (!_hasInitialScrolled) {
        _hasInitialScrolled = true;
        _scrollController.jumpTo(maxScroll);
      } else if (forceScroll || (maxScroll - currentScroll) < 150) {
        _scrollController.animateTo(
          maxScroll,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  // Send message using Ably + Firestore
  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    // Stop typing indicator instantly
    if (_isMeTyping) {
      _isMeTyping = false;
      _sendTypingEvent(false);
    }

    // Sensory light haptic feedback when tapping Send (matches Instagram/Snapchat)
    HapticFeedback.lightImpact();

    final currentMood = _selectedMood;
    _startMoodResetTimer();

    try {
      // 1. Persist in Firestore
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .add({
        'sender': widget.currentUsername,
        'text': text,
        'timestamp': FieldValue.serverTimestamp(),
        'isEdited': false,
        'deletedForEveryone': false,
        'deletedFor': <String>[],
        'starredBy': <String>[],
        'seen': false,
        'mood': currentMood,
        if (_disappearingDuration > 0) 'disappearingDuration': _disappearingDuration,
      });

      // 2. Publish via Ably for instant delivery
      if (AblyService.instance.isInitialized && _ablyChannel != null) {
        await AblyService.instance.publishMessage(
          channel: _ablyChannel,
          sender: widget.currentUsername,
          text: text,
        );
      }

      // 3. Update parent chat doc
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .set({
        'lastMessage': text,
        'lastSender': widget.currentUsername,
        'lastTimestamp': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'participants': [
          widget.currentUsername.toLowerCase(),
          widget.targetUsername.toLowerCase()
        ],
      }, SetOptions(merge: true));

      // 4. Restore chat to active list for both participants (unhide if hidden)
      await FirebaseFirestore.instance
          .collection('relationships')
          .doc(_relationshipKey)
          .update({
        'hiddenBy': FieldValue.arrayRemove([
          widget.currentUsername.toLowerCase(),
          widget.targetUsername.toLowerCase()
        ])
      }).catchError((_) {});

      _triggerSmartScroll(forceScroll: true);
    } catch (_) {}
  }

  // Send an animated Noto emoji (via prefix in message text)
  Future<void> _sendAnimatedEmoji(String codepoint) async {
    final text = 'anim_emoji_noto:$codepoint';
    
    // Add to recent emojis list locally
    setState(() {
      if (!_recentAnimatedEmojiCodes.contains(codepoint)) {
        _recentAnimatedEmojiCodes.insert(0, codepoint);
        if (_recentAnimatedEmojiCodes.length > 35) {
          _recentAnimatedEmojiCodes.removeLast();
        }
      } else {
        _recentAnimatedEmojiCodes.remove(codepoint);
        _recentAnimatedEmojiCodes.insert(0, codepoint);
      }
    });
    _precacheEmojis();

    // Save recent emojis persistently to Firestore
    _saveRecentEmojisToFirestore();

    // Sensory light haptic feedback
    HapticFeedback.lightImpact();

    final currentMood = _selectedMood;
    _startMoodResetTimer();

    try {
      // 1. Persist in Firestore
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .add({
        'sender': widget.currentUsername,
        'text': text,
        'timestamp': FieldValue.serverTimestamp(),
        'isEdited': false,
        'deletedForEveryone': false,
        'deletedFor': <String>[],
        'starredBy': <String>[],
        'seen': false,
        'mood': currentMood,
        if (_disappearingDuration > 0) 'disappearingDuration': _disappearingDuration,
      });

      // 2. Publish via Ably for instant delivery
      if (AblyService.instance.isInitialized && _ablyChannel != null) {
        await AblyService.instance.publishMessage(
          channel: _ablyChannel,
          sender: widget.currentUsername,
          text: text,
        );
      }

      // 3. Update parent chat doc
      String displayEmoji = 'Animated Emoji 🎬';
      try {
        final cpParts = codepoint.split('_');
        displayEmoji = cpParts.map((part) => String.fromCharCode(int.parse(part, radix: 16))).join();
      } catch (_) {}

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .set({
        'lastMessage': displayEmoji,
        'lastSender': widget.currentUsername,
        'lastTimestamp': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'participants': [
          widget.currentUsername.toLowerCase(),
          widget.targetUsername.toLowerCase()
        ],
      }, SetOptions(merge: true));

      // 4. Restore chat to active list for both participants (unhide if hidden)
      await FirebaseFirestore.instance
          .collection('relationships')
          .doc(_relationshipKey)
          .update({
        'hiddenBy': FieldValue.arrayRemove([
          widget.currentUsername.toLowerCase(),
          widget.targetUsername.toLowerCase()
        ])
      }).catchError((_) {});

      _triggerSmartScroll(forceScroll: true);
    } catch (_) {}
  }

  void _precacheEmojis() {
    if (!mounted) return;
    for (var code in _recentAnimatedEmojiCodes) {
      precacheImage(
        AssetImage('assets/emojis/$code.webp'),
        context,
      ).catchError((_) {});
    }
  }

  // Load recently used emojis from user's Firestore document
  Future<void> _loadRecentEmojis() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('userdetails')
          .where('username', isEqualTo: widget.currentUsername)
          .limit(1)
          .get();
      if (snapshot.docs.isNotEmpty && mounted) {
        final data = snapshot.docs.first.data();
        final list = List<String>.from(data['recentEmojis'] ?? []);
        if (list.isNotEmpty) {
          setState(() {
            _recentAnimatedEmojiCodes.clear();
            _recentAnimatedEmojiCodes.addAll(list);
          });
          _precacheEmojis();
        }
      }
    } catch (_) {}
  }

  // Save recently used emojis persistently to user's Firestore document
  Future<void> _saveRecentEmojisToFirestore() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('userdetails')
          .where('username', isEqualTo: widget.currentUsername)
          .limit(1)
          .get();
      if (snapshot.docs.isNotEmpty) {
        final docRef = snapshot.docs.first.reference;
        await docRef.update({
          'recentEmojis': _recentAnimatedEmojiCodes,
        });
      }
    } catch (_) {}
  }

  // Toggle message reactions in Firestore and notify via Ably
  Future<void> _reactToMessage(String messageId, String emoji) async {
    // Sensory light haptic feedback
    HapticFeedback.lightImpact();

    try {
      final docRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .doc(messageId);

      final snap = await docRef.get();
      if (!snap.exists) return;

      final data = snap.data() as Map<String, dynamic>;
      final Map<String, String> reactions = Map<String, String>.from(data['reactions'] ?? {});
      
      final String myUsername = widget.currentUsername.toLowerCase();

      if (reactions[myUsername] == emoji) {
        reactions.remove(myUsername);
      } else {
        reactions[myUsername] = emoji;
      }

      await docRef.update({
        'reactions': reactions,
      });

      // Notify Ably listeners for real-time sync in active view
      if (AblyService.instance.isInitialized && _ablyChannel != null) {
        await AblyService.instance.publishMessage(
          channel: _ablyChannel,
          sender: widget.currentUsername,
          text: 'reaction_update:$messageId',
        );
      }
    } catch (_) {}
  }

  Color _getMoodColor(String mood, bool isMe) {
    switch (mood.toLowerCase()) {
      case 'angry':
        return const Color(0xFFFF1A1A); // Vibrant fire red
      case 'happy':
        return const Color(0xFFFFD60A); // Electric gold yellow
      case 'sad':
        return const Color(0xFF0A84FF); // Electric blue
      case 'tension':
        return const Color(0xFFFF9F0A); // Saturated orange
      case 'excited':
        return const Color(0xFFBF5AF2); // Neon purple
      case 'chill':
        return const Color(0xFF30D158); // Saturated green
      case 'child safety':
      case 'childsafety':
      case 'child_safety':
        return const Color(0xFF00E5FF); // Vibrant neon cyan/teal
      default:
        return const Color(0xFFD1D1D6); // Saturated silver/grey
    }
  }

  String? _getAnimatedEmojiCodepoint(String char) {
    for (var list in NotoEmojiData.categories.values) {
      for (var emoji in list) {
        if (emoji.char == char) return emoji.code;
      }
    }
    return null;
  }

  // Build the premium visual badge layout for message reactions (ultra-compact floating style)
  Widget _buildMessageReactions(Map<String, String> reactions, String messageId, bool isMe) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    // Group reactions by emoji and count their frequencies
    final Map<String, int> emojiCounts = {};
    reactions.forEach((user, emoji) {
      emojiCounts[emoji] = (emojiCounts[emoji] ?? 0) + 1;
    });

    final pill = GestureDetector(
      onTap: () => _showReactionReactorsSheet(messageId, reactions),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3.5),
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E), // Solid dark grey
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white,
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black,
              blurRadius: 3,
              spreadRadius: 0.5,
              offset: const Offset(0, 1.5),
            ),
          ],
        ),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...emojiCounts.entries.map((entry) {
              final emoji = entry.key;
              final count = entry.value;
              final codepoint = _getAnimatedEmojiCodepoint(emoji);

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (codepoint != null)
                      CachedNetworkImage(
                        imageUrl: 'https://fonts.gstatic.com/s/e/notoemoji/latest/$codepoint/512.webp',
                        width: 18,
                        height: 18,
                        fit: BoxFit.contain,
                        errorWidget: (context, url, error) => Image.asset(
                          'assets/emojis/$codepoint.webp',
                          width: 18,
                          height: 18,
                          fit: BoxFit.contain,
                          errorBuilder: (context, err, st) => Text(
                            emoji,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                    else
                      Text(
                        emoji,
                        style: const TextStyle(fontSize: 12),
                      ),
                    if (count > 1) ...[
                      const SizedBox(width: 2.5),
                      Text(
                        '$count',
                        style: const TextStyle(
                          color: Color(0xFFE5E5EA),
                          fontSize: 9.0,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Plus Jakarta Sans',
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
            if (reactions.length > 1 && emojiCounts.length > 1) ...[
              const SizedBox(width: 4),
              Container(
                width: 1,
                height: 10,
                color: Colors.white24,
              ),
              const SizedBox(width: 4),
              Text(
                '${reactions.length}',
                style: const TextStyle(
                  color: Color(0xFFE5E5EA),
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Plus Jakarta Sans',
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 0, bottom: 2),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Slight and light visible straight vertical line directing to the message
          Padding(
            padding: EdgeInsets.only(
              right: isMe ? 16.0 : 0.0,
              left: isMe ? 0.0 : 16.0,
            ),
            child: Container(
              width: 1.5,
              height: 3.5,
              color: Colors.white, // clearly visible yet light and elegant
            ),
          ),
          pill,
        ],
      ),
    );
  }

  // Show premium modal sheet listing all reactors and their custom emoji reactions
  void _showReactionReactorsSheet(String messageId, Map<String, String> reactions) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Reactions',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Divider(color: Color(0xFF2C2C2E), thickness: 1.0),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: reactions.entries.map((entry) {
                    final username = entry.key;
                    final emoji = entry.value;
                    final isMe = username.toLowerCase() == widget.currentUsername.toLowerCase();

                    // Generate a nice profile avatar color dynamically based on username hash
                    final int hash = username.codeUnits.fold(0, (prev, elem) => prev + elem);
                    final List<Color> colors = [
                      const Color(0xFFFF453A),
                      const Color(0xFF30D158),
                      const Color(0xFF0A84FF),
                      const Color(0xFFBF5AF2),
                      const Color(0xFFFF9F0A),
                      const Color(0xFFFF375F),
                    ];
                    final Color avatarColor = colors[hash % colors.length];

                    return ListTile(
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: avatarColor,
                        child: Text(
                          username.isNotEmpty ? username[0].toUpperCase() : '?',
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                      title: Text(
                        isMe ? 'You (@$username)' : '@$username',
                        style: const TextStyle(color: Colors.white, fontSize: 14.5),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            emoji,
                            style: const TextStyle(fontSize: 20),
                          ),
                          if (isMe) ...[
                            const SizedBox(width: 12),
                            IconButton(
                              icon: const Icon(Icons.cancel_outlined, color: Color(0xFF8E8E93), size: 20),
                              tooltip: 'Remove my reaction',
                              onPressed: () {
                                Navigator.pop(context);
                                _reactToMessage(messageId, emoji);
                              },
                            ),
                          ],
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  // Show premium Google-Messages-style Camera Option Selector (Photo vs Video)
  void _showCameraOptionSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161618),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A3A3C),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                const Text(
                  'Camera Capture',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildCameraChoiceButton(
                      label: 'Take Photo',
                      icon: Icons.camera_alt,
                      color: const Color(0xFFFBBC05), // Yellow
                      onTap: () {
                        Navigator.pop(context);
                        _pickAndSendMedia(ImageSource.camera, isVideo: false);
                      },
                    ),
                    _buildCameraChoiceButton(
                      label: 'Record Video',
                      icon: Icons.videocam,
                      color: const Color(0xFFFF453A), // Red
                      onTap: () {
                        Navigator.pop(context);
                        _pickAndSendMedia(ImageSource.camera, isVideo: true);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCameraChoiceButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              shape: BoxShape.circle,
              border: Border.all(color: color.withAlpha(120), width: 1.5),
            ),
            child: Icon(
              icon,
              color: color,
              size: 28,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // Show premium Noto Animated Emoji bottom sheet selector
  void _showAnimatedEmojiSheet({bool isReactionMode = false, String? reactionMessageId}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161618),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        String activeCategory = 'Recent';
        String searchQuery = '';
        final searchController = TextEditingController();

        return StatefulBuilder(
          builder: (context, setModalState) {
            List<NotoEmoji> displayList = [];
            
            if (searchQuery.isNotEmpty) {
              // Filter emojis across all categories by tags/keywords
              NotoEmojiData.categories.forEach((cat, emojis) {
                for (var e in emojis) {
                  final matchesTag = e.tags.any((tag) => tag.toLowerCase().contains(searchQuery.toLowerCase()));
                  if (matchesTag && !displayList.any((item) => item.code == e.code)) {
                    displayList.add(e);
                  }
                }
              });
            } else if (activeCategory == 'Recent') {
              // Load from local static recent list
              for (var code in _recentAnimatedEmojiCodes) {
                NotoEmoji? found;
                for (var list in NotoEmojiData.categories.values) {
                  for (var e in list) {
                    if (e.code == code) {
                      found = e;
                      break;
                    }
                  }
                  if (found != null) break;
                }
                if (found != null) {
                  displayList.add(found);
                }
              }
            } else {
              displayList = NotoEmojiData.categories[activeCategory] ?? [];
            }

            final double sheetHeight = MediaQuery.of(context).size.height * 0.58;

            return Container(
              height: sheetHeight,
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                children: [
                  // Premium Drag Handle
                  Container(
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A3A3C),
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Search input bar
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: searchController,
                        style: const TextStyle(color: Colors.white, fontSize: 15.0),
                        onChanged: (val) {
                          setModalState(() {
                            searchQuery = val.trim();
                          });
                        },
                        decoration: InputDecoration(
                          hintText: 'Search emojis...',
                          hintStyle: const TextStyle(color: Color(0xFF8E8E93), fontSize: 15.0),
                          prefixIcon: const Icon(Icons.search, color: Color(0xFF8E8E93), size: 20),
                          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 20),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          suffixIcon: searchQuery.isNotEmpty
                              ? GestureDetector(
                                  onTap: () {
                                    setModalState(() {
                                      searchController.clear();
                                      searchQuery = '';
                                    });
                                  },
                                  child: const Icon(Icons.close, color: Color(0xFF8E8E93), size: 16),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                   // Horizontal category scrolling tabs selector
                  if (searchQuery.isEmpty)
                    SizedBox(
                      height: 38,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          // Recent tab first
                          GestureDetector(
                            onTap: () {
                              setModalState(() {
                                activeCategory = 'Recent';
                              });
                            },
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: activeCategory == 'Recent' ? const Color(0xFF2C2C2E) : Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                                border: activeCategory == 'Recent'
                                    ? Border.all(color: Colors.white, width: 1)
                                    : null,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    'Recent',
                                    style: TextStyle(
                                      color: activeCategory == 'Recent' ? Colors.white : const Color(0xFF8E8E93),
                                      fontWeight: activeCategory == 'Recent' ? FontWeight.w600 : FontWeight.normal,
                                      fontSize: 12.0,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          ...NotoEmojiData.categories.keys.map((cat) {
                            final isSelected = cat == activeCategory;

                            return GestureDetector(
                              onTap: () {
                                setModalState(() {
                                  activeCategory = cat;
                                });
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 3),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFF2C2C2E) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(16),
                                  border: isSelected
                                      ? Border.all(color: Colors.white, width: 1)
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      cat,
                                      style: TextStyle(
                                        color: isSelected ? Colors.white : const Color(0xFF8E8E93),
                                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                        fontSize: 12.0,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  if (searchQuery.isEmpty) const SizedBox(height: 4),

                  // Grid of Emojis
                  Expanded(
                    child: displayList.isEmpty
                        ? const Center(
                            child: Text(
                              'No matching animated emojis',
                              style: TextStyle(color: Colors.grey, fontSize: 14.5),
                            ),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 8,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: displayList.length,
                            itemBuilder: (context, index) {
                              final emojiObj = displayList[index];
                              final codepoint = _getAnimatedEmojiCodepoint(emojiObj.char);

                              return GestureDetector(
                                onTap: () {
                                  Navigator.pop(context);
                                  if (isReactionMode && reactionMessageId != null) {
                                    _reactToMessage(reactionMessageId, emojiObj.char);
                                  } else {
                                    _sendAnimatedEmoji(emojiObj.code);
                                  }
                                },
                                behavior: HitTestBehavior.opaque,
                                child: Center(
                                  child: codepoint != null
                                      ? CachedNetworkImage(
                                          imageUrl: 'https://fonts.gstatic.com/s/e/notoemoji/latest/$codepoint/512.webp',
                                          width: 32,
                                          height: 32,
                                          fit: BoxFit.contain,
                                          placeholder: (context, url) => SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: Center(
                                              child: SizedBox(
                                                width: 12,
                                                height: 12,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 1.5,
                                                  valueColor: AlwaysStoppedAnimation<Color>(
                                                    isReactionMode ? Colors.amber : const Color(0xFF0A84FF),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          errorWidget: (context, url, error) => Image.asset(
                                            'assets/emojis/$codepoint.webp',
                                            width: 32,
                                            height: 32,
                                            fit: BoxFit.contain,
                                            errorBuilder: (context, err, st) => Text(
                                              emojiObj.char,
                                              style: const TextStyle(fontSize: 24),
                                            ),
                                          ),
                                        )
                                      : Text(
                                          emojiObj.char,
                                          style: const TextStyle(fontSize: 24),
                                        ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Mark all incoming messages from target user as read
  void _markMessagesAsSeen(List<DocumentSnapshot> messages) {
    final batch = FirebaseFirestore.instance.batch();
    bool hasUpdates = false;

    for (var doc in messages) {
      final data = doc.data() as Map<String, dynamic>;
      final sender = data['sender'] as String? ?? '';
      final seen = data['seen'] as bool? ?? false;

      if (sender.toLowerCase() == widget.targetUsername.toLowerCase() && !seen) {
        batch.update(doc.reference, {'seen': true});
        hasUpdates = true;
      }
    }

    if (hasUpdates) {
      batch.commit();
    }
  }

  // Edit an existing message
  Future<void> _editMessage(String messageId, String newText) async {
    if (newText.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .doc(messageId)
          .update({
        'text': newText,
        'isEdited': true,
      });

      // Publish Ably notification to sync instantly
      if (AblyService.instance.isInitialized && _ablyChannel != null) {
        await _ablyChannel.publish(
          name: 'message_edit',
          data: {'messageId': messageId, 'text': newText},
        );
      }
    } catch (_) {}
  }

  // Delete message for everyone
  Future<void> _deleteMessageForEveryone(String messageId) async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .doc(messageId)
          .update({
        'deletedForEveryone': true,
        'text': 'This message was deleted',
      });

      final lastMsgSnap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .get();

      if (lastMsgSnap.exists) {
        final data = lastMsgSnap.data();
        if (data?['lastMessage'] != null) {
          await FirebaseFirestore.instance
              .collection('chats')
              .doc(_channelName)
              .update({
            'lastMessage': 'This message was deleted',
          });
        }
      }
    } catch (_) {}
  }

  // Delete message for me only
  Future<void> _deleteMessageForMe(String messageId, List<dynamic> currentDeletedFor) async {
    try {
      final updated = List<String>.from(currentDeletedFor);
      if (!updated.contains(widget.currentUsername)) {
        updated.add(widget.currentUsername);
      }

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .doc(messageId)
          .update({
        'deletedFor': updated,
      });
    } catch (_) {}
  }

  // Toggle star message
  Future<void> _toggleStarMessage(String messageId, List<dynamic> currentStarredBy) async {
    try {
      final updated = List<String>.from(currentStarredBy);
      if (updated.contains(widget.currentUsername)) {
        updated.remove(widget.currentUsername);
      } else {
        updated.add(widget.currentUsername);
      }

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .doc(messageId)
          .update({
        'starredBy': updated,
      });
    } catch (_) {}
  }

  // Clear chat for current user
  Future<void> _clearChat() async {
    try {
      final messagesSnap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (var doc in messagesSnap.docs) {
        final data = doc.data();
        final deletedFor = List<String>.from(data['deletedFor'] ?? []);
        if (!deletedFor.contains(widget.currentUsername)) {
          deletedFor.add(widget.currentUsername);
          batch.update(doc.reference, {'deletedFor': deletedFor});
        }
      }
      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat history cleared'),
          backgroundColor: Colors.grey,
        ),
      );
    } catch (_) {}
  }

  // Show starred messages in a bottom sheet
  // ignore: unused_element
  void _showStarredMessages() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Starred Messages ⭐',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(color: Color(0xFF2C2C2E)),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('chats')
                      .doc(_channelName)
                      .collection('messages')
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final starredMsgs = snapshot.data!.docs.where((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final starredBy = List<String>.from(data['starredBy'] ?? []);
                      final deletedFor = List<String>.from(data['deletedFor'] ?? []);
                      return starredBy.contains(widget.currentUsername) &&
                          !deletedFor.contains(widget.currentUsername) &&
                          !(data['deletedForEveryone'] ?? false);
                    }).toList();

                    if (starredMsgs.isEmpty) {
                      return const Center(
                        child: Text(
                          'No starred messages yet',
                          style: TextStyle(color: Colors.grey, fontSize: 16),
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: starredMsgs.length,
                      itemBuilder: (context, index) {
                        final data = starredMsgs[index].data() as Map<String, dynamic>;
                        final text = data['text'] ?? '';
                        final sender = data['sender'] ?? '';
                        final isMe = sender.toLowerCase() == widget.currentUsername.toLowerCase();

                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2C2C2E),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isMe ? 'You' : '@$sender',
                                style: TextStyle(
                                  color: isMe ? const Color(0xFF0A84FF) : const Color(0xFFFF453A),
                                  fontWeight: FontWeight.normal,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                text,
                                style: const TextStyle(color: Colors.white, fontSize: 15),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Edit Dialog
  void _showEditDialog(String messageId, String currentText) {
    _editController.text = currentText;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          title: const Text('Edit Message', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: _editController,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Enter new message...',
              hintStyle: TextStyle(color: Colors.grey),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.grey),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.blue),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                _editMessage(messageId, _editController.text.trim());
                Navigator.pop(context);
              },
              child: const Text('Save', style: TextStyle(color: Colors.blue)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _translateMessage(String messageId, String text) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF0A84FF)),
      ),
    );

    try {
      final String translated = await TranslationService.translate(text, _targetTranslationLanguage);
      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading spinner

      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.translate, color: Color(0xFF0A84FF), size: 20),
                const SizedBox(width: 8),
                Text('Translated to $_targetTranslationLanguage', style: const TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
            content: Text(
              translated,
              style: const TextStyle(color: Colors.white, fontSize: 15.5, height: 1.4),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close', style: TextStyle(color: Color(0xFF0A84FF))),
              ),
            ],
          );
        },
      );
    } catch (_) {
      if (mounted) {
        Navigator.pop(context); // Dismiss loading if it failed
      }
    }
  }

  void _showGetMeaningSheet(String text) {
    final analysis = AIAssistantService.getMessageMeaning(text);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[600],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Row(
                    children: [
                      Icon(Icons.psychology, color: Color(0xFF0A84FF), size: 24),
                      SizedBox(width: 10),
                      Text(
                        'Tone & Semantic Analysis',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Original Message:',
                    style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    text,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: Color(0xFF2C2C2E)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        'Tone Profile:  ',
                        style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        analysis['tone'] ?? 'Neutral 😐',
                        style: const TextStyle(color: Color(0xFF30D158), fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Semantic Meaning:',
                    style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    analysis['meaning'] ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.3),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Empathy Recommendation:',
                    style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    analysis['empathy'] ?? '',
                    style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.3),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showAITransformDialog() {
    String selectedMood = _selectedMood != 'Neutral' ? _selectedMood : 'Happy';
    String selectedLanguage = _targetTranslationLanguage;
    final roughDraftController = TextEditingController();
    bool isGenerating = false;
    String generatedResult = '';

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Helper function to automatically re-generate the AI text with updated parameters
            Future<void> triggerAutoRegenerate() async {
              if (roughDraftController.text.isEmpty) return;
              setDialogState(() {
                isGenerating = true;
                generatedResult = '';
              });
              try {
                final res = await AIAssistantService.transformMessage(
                  roughDraft: roughDraftController.text,
                  mood: selectedMood,
                  targetLanguage: selectedLanguage,
                );
                setDialogState(() {
                  generatedResult = res;
                  isGenerating = false;
                });
              } catch (_) {
                setDialogState(() {
                  isGenerating = false;
                });
              }
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF1C1C1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.auto_awesome, color: Color(0xFFBF5AF2), size: 22),
                  SizedBox(width: 8),
                  Text('AI Auto-Transform', style: TextStyle(color: Colors.white, fontSize: 16)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Selected Mood', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2E),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedMood,
                          dropdownColor: const Color(0xFF1C1C1E),
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                          isExpanded: true,
                          items: ['Neutral', 'Angry', 'Happy', 'Sad', 'Tension', 'Excited', 'Chill'].map((m) {
                            return DropdownMenuItem<String>(value: m, child: Text(m));
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setDialogState(() {
                                selectedMood = val;
                              });
                              // Auto-regenerate if there is already a generated output
                              if (generatedResult.isNotEmpty) {
                                triggerAutoRegenerate();
                              }
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Target Language', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2E),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedLanguage,
                          dropdownColor: const Color(0xFF1C1C1E),
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                          isExpanded: true,
                          items: [
                            'English', 'Spanish', 'French', 'German', 'Hindi',
                            'Arabic', 'Japanese', 'Chinese', 'Portuguese', 'Italian',
                            'Russian', 'Telugu', 'Tamil', 'Bengali',
                          ].map((l) {
                            return DropdownMenuItem<String>(value: l, child: Text(l));
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setDialogState(() {
                                selectedLanguage = val;
                              });
                              // Auto-regenerate if there is already a generated output
                              if (generatedResult.isNotEmpty) {
                                triggerAutoRegenerate();
                              }
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Rough Draft / Idea', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: roughDraftController,
                      maxLines: 3,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'e.g., tell him i will be late because of traffic',
                        hintStyle: const TextStyle(color: Colors.grey, fontSize: 13.5),
                        fillColor: const Color(0xFF2C2C2E),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    if (isGenerating) ...[
                      const SizedBox(height: 16),
                      const Center(
                        child: CircularProgressIndicator(color: Color(0xFFBF5AF2)),
                      ),
                    ] else if (generatedResult.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text('Generated Output:', style: TextStyle(color: Color(0xFFBF5AF2), fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2438),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFBF5AF2), width: 1.0),
                        ),
                        child: Text(
                          generatedResult,
                          style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.3),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                if (generatedResult.isEmpty)
                  TextButton(
                    onPressed: () async {
                      setDialogState(() {
                        isGenerating = true;
                      });
                      try {
                        final res = await AIAssistantService.transformMessage(
                          roughDraft: roughDraftController.text,
                          mood: selectedMood,
                          targetLanguage: selectedLanguage,
                        );
                        setDialogState(() {
                          generatedResult = res;
                          isGenerating = false;
                        });
                      } catch (_) {
                        setDialogState(() {
                          isGenerating = false;
                        });
                      }
                    },
                    child: const Text('Generate', style: TextStyle(color: Color(0xFFBF5AF2), fontWeight: FontWeight.bold)),
                  )
                else
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedMood = selectedMood; // Set main page mood to the AI dialog's selected mood
                      });
                      _messageController.text = generatedResult;
                      Navigator.pop(context);
                    },
                    child: const Text('Use Message', style: TextStyle(color: Color(0xFF30D158), fontWeight: FontWeight.bold)),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  // Long press actions sheet (like Google Messages)
  void _showMessageOptions(String messageId, Map<String, dynamic> data) {
    final sender = data['sender'] as String? ?? '';
    final text = data['text'] as String? ?? '';
    final isMe = sender.toLowerCase() == widget.currentUsername.toLowerCase();
    final starredBy = List<String>.from(data['starredBy'] ?? []);
    final isStarred = starredBy.contains(widget.currentUsername);
    final deletedFor = List<String>.from(data['deletedFor'] ?? []);
    final deletedForEveryone = data['deletedForEveryone'] as bool? ?? false;
    final reactionsMap = Map<String, String>.from(data['reactions'] ?? {});
    final myReaction = reactionsMap[widget.currentUsername.toLowerCase()];

    // Haptic feedback selection vibration on long press (premium Snapchat/Instagram feeling)
    HapticFeedback.mediumImpact();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              if (!deletedForEveryone) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        ...['❤️', '👍', '😂', '😮', '😢', '🙏'].map((emoji) {
                          final myUsername = widget.currentUsername.toLowerCase();
                          final reactions = Map<String, String>.from(data['reactions'] ?? {});
                          final currentReaction = reactions[myUsername];
                          final isSelected = currentReaction == emoji;

                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: GestureDetector(
                              onTap: () {
                                Navigator.pop(context);
                                _reactToMessage(messageId, emoji);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFF2C2C2E) : Colors.transparent,
                                  shape: BoxShape.circle,
                                  border: isSelected
                                      ? Border.all(color: Colors.white, width: 1.0)
                                      : null,
                                ),
                                child: Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 18),
                                ),
                              ),
                            ),
                          );
                        }),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _showAnimatedEmojiSheet(isReactionMode: true, reactionMessageId: messageId);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2C2C2E),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 1.0),
                              ),
                              child: const Icon(
                                Icons.add,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(color: Color(0xFF2C2C2E), thickness: 1.0),
              ],
              if (!deletedForEveryone && myReaction != null) ...[
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                  title: const Text('Remove my Reaction', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    _reactToMessage(messageId, myReaction);
                  },
                ),
                const Divider(color: Color(0xFF2C2C2E), thickness: 1.0),
              ],
              if (!deletedForEveryone) ...[
                ListTile(
                  leading: const Icon(Icons.translate, color: Color(0xFF30D158)),
                  title: Text('Translate to $_targetTranslationLanguage', style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    _translateMessage(messageId, text);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.psychology, color: Color(0xFFBF5AF2)),
                  title: const Text('Get Meaning', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    _showGetMeaningSheet(text);
                  },
                ),
                ListTile(
                  leading: Icon(
                    isStarred ? Icons.star : Icons.star_border,
                    color: isStarred ? Colors.amber : Colors.white,
                  ),
                  title: Text(
                    isStarred ? 'Unstar Message' : 'Star Message',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _toggleStarMessage(messageId, starredBy);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy, color: Colors.white),
                  title: const Text('Copy Text', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Message copied to clipboard'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
                if (isMe)
                  ListTile(
                    leading: const Icon(Icons.edit, color: Colors.blue),
                    title: const Text('Edit Message', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      _showEditDialog(messageId, text);
                    },
                  ),
              ],
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.white),
                title: const Text('Delete for Me', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessageForMe(messageId, deletedFor);
                },
              ),
              if (isMe && !deletedForEveryone)
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
                  title: const Text(
                    'Delete for Everyone',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _deleteMessageForEveryone(messageId);
                  },
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    },
  );
}



  @override
  Widget build(BuildContext context) {
    final lowerTargetName = widget.targetUsername.toLowerCase();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          _buildFloatingHeaderBar(lowerTargetName),
          // ═══════════════════════════════════════════════════
          // ELEMENT 1: Chronological Chat Messages with smart auto-scroll & continuous vertical margins
          // ═══════════════════════════════════════════════════
          Expanded(
            child: Stack(
              children: [
                StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(_channelName)
                  .collection('messages')
                  .orderBy('timestamp', descending: false)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text('Error loading messages', style: TextStyle(color: Colors.grey)),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final now = DateTime.now();
                final docs = snapshot.data!.docs;
                final messages = docs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final deletedFor = List<String>.from(data['deletedFor'] ?? []);
                  if (deletedFor.contains(widget.currentUsername)) return false;

                  // Disappearing messages check
                  final msgDisappearingDuration = data['disappearingDuration'] as int? ?? 0;
                  final timestamp = data['timestamp'] as Timestamp?;
                  if (msgDisappearingDuration > 0 && timestamp != null) {
                    final disappearTime = timestamp.toDate().toLocal().add(Duration(seconds: msgDisappearingDuration));
                    if (now.isAfter(disappearTime)) {
                      // Trigger delete in background
                      _deleteMessageFromDisappearing(doc.id);
                      return false;
                    }
                  }
                  return true;
                }).toList();

                // Fire real-time read receipt updates
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _markMessagesAsSeen(messages);
                  _checkAndTriggerDownloads(messages);
                });

                if (messages.isEmpty) {
                  return Container(
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      image: DecorationImage(
                        image: AssetImage('assets/images/chat_bg_dense.png'),
                        fit: BoxFit.cover,
                        opacity: 0.15,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        'No messages yet. Say hello to @$lowerTargetName! 👋',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey, fontSize: 15),
                      ),
                    ),
                  );
                }

                // Dynamic Grouping of consecutive messages by sender
                List<MessageGroup> groups = [];


                for (var doc in messages) {
                  final data = doc.data() as Map<String, dynamic>;
                  final sender = data['sender'] as String? ?? '';

                  bool createNewGroup = false;
                  if (groups.isEmpty) {
                    createNewGroup = true;
                  } else if (groups.last.sender.toLowerCase() != sender.toLowerCase()) {
                    createNewGroup = true;
                  }

                  if (createNewGroup) {
                    groups.add(MessageGroup(sender: sender, docs: [doc]));
                  } else {
                    groups.last.docs.add(doc);
                  }
                }

                // Inject centered timeline timestamps dynamically and render groups (gaps >= 2 min or sender switches)
                List<Widget> listItems = [];
                DateTime? lastDisplayedTime;

                for (int g = 0; g < groups.length; g++) {
                  final group = groups[g];
                  final isMe = group.sender.toLowerCase() == widget.currentUsername.toLowerCase();

                  // Get group timestamp
                  final firstDoc = group.docs.first;
                  final firstData = firstDoc.data() as Map<String, dynamic>;
                  final firstTs = firstData['timestamp'] as Timestamp?;
                  final groupTime = firstTs?.toDate().toLocal() ?? DateTime.now();

                  // Show timestamp at start, on sender changes, or when gap >= 2 minutes
                  if (g == 0 || lastDisplayedTime == null ||
                      groups[g].sender.toLowerCase() != groups[g - 1].sender.toLowerCase() ||
                      groupTime.difference(lastDisplayedTime).inMinutes.abs() >= 2) {
                    listItems.add(
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Divider(
                                color: Colors.white.withAlpha(30),
                                thickness: 0.5,
                                indent: 16,
                                endIndent: 8,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1E22).withAlpha(217), // Frosted glass dark grey
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white.withAlpha(30), width: 0.8),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withAlpha(102),
                                      blurRadius: 6,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  DateFormat('h:mm a').format(groupTime),
                                  style: const TextStyle(
                                    color: Color(0xFFE5E5EA), // Brighter, premium white/grey text
                                    fontFamily: 'Plus Jakarta Sans',
                                    fontSize: 11.0,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
                                color: Colors.white.withAlpha(30),
                                thickness: 0.5,
                                indent: 8,
                                endIndent: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  lastDisplayedTime = groupTime;

                  // Build the continuous message group row with per-message custom colored sidelines
                  listItems.add(
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 16),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // 3RD LAYER: Continuous Solid Side Line with reduced thickness and neon glow
                          Positioned(
                            top: 2,
                            bottom: 2,
                            left: isMe ? null : 0,
                            right: isMe ? 0 : null,
                            child: Container(
                              width: 3.0, // Reduced thickness from 4.5!
                              decoration: BoxDecoration(
                                color: isMe ? const Color(0xFF0A84FF) : const Color(0xFFFF453A),
                                borderRadius: BorderRadius.circular(1.5),
                              ),
                            ),
                          ),
                          Padding(
                            padding: isMe
                                ? const EdgeInsets.only(right: 15) // Clear right side line
                                : const EdgeInsets.only(left: 15),  // Clear left side line
                            child: Column(
                              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: group.docs.map((doc) {
                                final data = doc.data() as Map<String, dynamic>;
                                final text = data['text'] as String? ?? '';
                                final timestamp = data['timestamp'] as Timestamp?;
                                final isStarred = List<String>.from(data['starredBy'] ?? []).contains(widget.currentUsername);
                                final isEdited = data['isEdited'] as bool? ?? false;
                                final deletedForEveryone = data['deletedForEveryone'] as bool? ?? false;

                                // Click status display logic
                                final bool isLastDoc = (doc.id == messages.last.id);
                                final bool showStatus = isLastDoc || _visibleStatusIds.contains(doc.id);

                                final bool isSelected = _selectedMessageIds.contains(doc.id);
                                final bool isHighlighted = _highlightedMessageId == doc.id;

                                // Auto-scroll to the highlighted message on first render
                                if (isHighlighted && !_hasScrolledToHighlight) {
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    if (_highlightKey.currentContext != null && !_hasScrolledToHighlight) {
                                      _hasScrolledToHighlight = true;
                                      Scrollable.ensureVisible(
                                        _highlightKey.currentContext!,
                                        duration: const Duration(milliseconds: 700),
                                        curve: Curves.easeInOut,
                                        alignment: 0.4,
                                      );
                                    }
                                  });
                                }

                                final String messageMood = data['mood'] as String? ?? 'Neutral';
                                final Color messageMoodColor = _getMoodColor(messageMood, isMe);
                                final Map<String, String> msgReactions = Map<String, String>.from(data['reactions'] ?? {});

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Padding(
                                      key: isHighlighted ? _highlightKey : null,
                                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                                      child: Row(
                                        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_isSelectMode) ...[
                                            GestureDetector(
                                              onTap: () {
                                                HapticFeedback.selectionClick();
                                                setState(() {
                                                  if (isSelected) {
                                                    _selectedMessageIds.remove(doc.id);
                                                  } else {
                                                    _selectedMessageIds.add(doc.id);
                                                  }
                                                });
                                              },
                                              child: AnimatedContainer(
                                                duration: const Duration(milliseconds: 200),
                                                width: 20,
                                                height: 20,
                                                margin: const EdgeInsets.only(right: 12),
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: isSelected
                                                      ? (isMe ? const Color(0xFF0A84FF) : const Color(0xFFFF453A))
                                                      : Colors.transparent,
                                                  border: Border.all(
                                                    color: isSelected
                                                        ? Colors.transparent
                                                        : const Color(0xFF3A3A3C),
                                                    width: 1.5,
                                                  ),
                                                ),
                                                child: isSelected
                                                    ? const Icon(Icons.check, color: Colors.white, size: 12)
                                                    : null,
                                              ),
                                            ),
                                          ],
                                          GestureDetector(
                                            onLongPress: () {
                                              if (_isSelectMode) {
                                                HapticFeedback.selectionClick();
                                                setState(() {
                                                  if (isSelected) {
                                                    _selectedMessageIds.remove(doc.id);
                                                  } else {
                                                    _selectedMessageIds.add(doc.id);
                                                  }
                                                });
                                              } else {
                                                _showMessageOptions(doc.id, data);
                                              }
                                            },
                                            onTap: () {
                                              final msgId = doc.id;
                                              HapticFeedback.selectionClick();
                                              if (_isSelectMode) {
                                                setState(() {
                                                  if (isSelected) {
                                                    _selectedMessageIds.remove(msgId);
                                                  } else {
                                                    _selectedMessageIds.add(msgId);
                                                  }
                                                });
                                              } else {
                                                setState(() {
                                                  _visibleStatusIds.add(msgId);
                                                });
                                                Timer(const Duration(seconds: 3), () {
                                                  if (mounted) {
                                                    setState(() {
                                                      _visibleStatusIds.remove(msgId);
                                                    });
                                                  }
                                                });
                                              }
                                            },
                                            behavior: HitTestBehavior.opaque,
                                            child: AnimatedContainer(
                                              duration: const Duration(milliseconds: 600),
                                              curve: Curves.easeOut,
                                              constraints: BoxConstraints(
                                                maxWidth: MediaQuery.of(context).size.width * 0.72,
                                              ),
                                              decoration: BoxDecoration(
                                                color: isHighlighted
                                                    ? Colors.amber
                                                    : isSelected
                                                        ? (isMe
                                                            ? const Color(0xFF0A84FF)
                                                            : const Color(0xFFFF453A))
                                                        : Colors.transparent,
                                                borderRadius: BorderRadius.circular(8),
                                                border: isHighlighted
                                                    ? Border.all(color: Colors.amber, width: 1.5)
                                                    : null,
                                              ),
                                              padding: (isSelected || isHighlighted)
                                                  ? const EdgeInsets.only(
                                                      left: 8,
                                                      right: 8,
                                                      top: 4,
                                                      bottom: 4,
                                                    )
                                                  : const EdgeInsets.only(
                                                      left: 0,
                                                      right: 0,
                                                      top: 0,
                                                      bottom: 0,
                                                    ),
                                              child: Column(
                                                crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                                children: [
                                                  Builder(
                                                    builder: (context) {
                                                      final msgType = data['type'] as String? ?? 'text';
                                                      if (!deletedForEveryone && msgType != 'text') {
                                                        return _buildCustomMessageCard(doc.id, data, isMe);
                                                      }

                                                      final isAnimEmoji = text.startsWith('anim_emoji_noto:') && !deletedForEveryone;
                                                      final emojiCodepoint = isAnimEmoji ? text.substring('anim_emoji_noto:'.length) : '';
                                                      
                                                      if (isAnimEmoji) {
                                                        return Container(
                                                          margin: const EdgeInsets.symmetric(vertical: 4),
                                                          child: CachedNetworkImage(
                                                            imageUrl: 'https://fonts.gstatic.com/s/e/notoemoji/latest/$emojiCodepoint/512.webp',
                                                            width: 75,
                                                            height: 75,
                                                            fit: BoxFit.contain,
                                                            placeholder: (context, url) => SizedBox(
                                                              width: 75,
                                                              height: 75,
                                                              child: Center(
                                                                child: SizedBox(
                                                                  width: 20,
                                                                  height: 20,
                                                                  child: CircularProgressIndicator(
                                                                    strokeWidth: 2,
                                                                    valueColor: AlwaysStoppedAnimation<Color>(
                                                                      isMe ? const Color(0xFF0A84FF) : const Color(0xFFFF453A),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                            errorWidget: (context, url, error) => Image.asset(
                                                              'assets/emojis/$emojiCodepoint.webp',
                                                              width: 75,
                                                              height: 75,
                                                              fit: BoxFit.contain,
                                                              errorBuilder: (context, error, stackTrace) {
                                                                String fallbackChar = '🎬';
                                                                try {
                                                                  final cpParts = emojiCodepoint.split('_');
                                                                  fallbackChar = cpParts.map((part) => String.fromCharCode(int.parse(part, radix: 16))).join();
                                                                } catch (_) {}
                                                                return Text(
                                                                  fallbackChar,
                                                                  style: const TextStyle(fontSize: 34),
                                                                );
                                                              },
                                                            ),
                                                          ),
                                                        );
                                                      }
                                                      
                                                      return Text.rich(
                                                        TextSpan(
                                                          children: [
                                                            if (isMe && isStarred)
                                                              const WidgetSpan(
                                                                alignment: PlaceholderAlignment.middle,
                                                                child: Padding(
                                                                  padding: EdgeInsets.only(right: 4),
                                                                  child: Icon(Icons.star, color: Colors.amber, size: 10),
                                                                ),
                                                              ),
                                                            TextSpan(
                                                              text: text,
                                                              style: TextStyle(
                                                                color: deletedForEveryone ? Colors.grey : Colors.white,
                                                                fontSize: deletedForEveryone ? 16.0 : 17.5,
                                                                fontStyle: deletedForEveryone ? FontStyle.italic : FontStyle.normal,
                                                                fontFamily: 'Plus Jakarta Sans',
                                                                fontFamilyFallback: const ['SF Pro Text', 'Helvetica Neue', 'sans-serif'],
                                                                fontWeight: FontWeight.w500,
                                                                height: 1.4,
                                                                letterSpacing: 0.2,
                                                              ),
                                                            ),
                                                            if (!isMe && isStarred)
                                                              const WidgetSpan(
                                                                alignment: PlaceholderAlignment.middle,
                                                                child: Padding(
                                                                  padding: EdgeInsets.only(left: 4),
                                                                  child: Icon(Icons.star, color: Colors.amber, size: 10),
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                        textAlign: isMe ? TextAlign.end : TextAlign.start,
                                                      );
                                                    },
                                                  ),
                                                  _buildMessageReactions(
                                                    msgReactions,
                                                    doc.id,
                                                    isMe,
                                                  ),
                                                  if (showStatus) ...[
                                                    const SizedBox(height: 6),
                                                    Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        if (messageMood != 'Neutral') ...[
                                                          Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                            decoration: BoxDecoration(
                                                              color: messageMoodColor.withAlpha(40),
                                                              borderRadius: BorderRadius.circular(4),
                                                            ),
                                                            child: Text(
                                                              messageMood.toLowerCase(),
                                                              style: TextStyle(
                                                                color: messageMoodColor,
                                                                fontFamily: 'Plus Jakarta Sans',
                                                                fontSize: 8.5,
                                                                fontWeight: FontWeight.w600,
                                                                letterSpacing: 0.3,
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(width: 4),
                                                        ],
                                                        Text(
                                                          DateFormat('h:mm a').format(timestamp?.toDate().toLocal() ?? DateTime.now()),
                                                          style: const TextStyle(
                                                            color: Colors.white60,
                                                            fontSize: 9.5,
                                                            fontFamily: 'Plus Jakarta Sans',
                                                          ),
                                                        ),
                                                        if (isEdited && !deletedForEveryone) ...[
                                                          const Text(' • ', style: TextStyle(color: Colors.white70, fontSize: 9.5)),
                                                          const Text(
                                                            'Edited',
                                                            style: TextStyle(
                                                              color: Colors.white60,
                                                              fontSize: 9.5,
                                                              fontFamily: 'Plus Jakarta Sans',
                                                            ),
                                                          ),
                                                        ],
                                                        if (isMe) ...[
                                                          const Text(' • ', style: TextStyle(color: Colors.white70, fontSize: 9.5)),
                                                          Text(
                                                            data['seen'] == true ? 'Seen' : 'Sent',
                                                            style: const TextStyle(
                                                              color: Colors.white60,
                                                              fontSize: 9.5,
                                                              fontFamily: 'Plus Jakarta Sans',
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                // Strict message count change detection scrolling (WONT jump or scroll on taps/seen updates!)
                final currentCount = messages.length;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!_scrollController.hasClients) return;
                  final maxScroll = _scrollController.position.maxScrollExtent;
                  final currentScroll = _scrollController.position.pixels;

                  // Solid Initial Scroll: ensure we always jump to bottom when opening the chat
                  if (!_hasInitialScrolled) {
                    _hasInitialScrolled = true;
                    _scrollController.jumpTo(maxScroll);
                    
                    // Repeated delayed checks to ensure dynamic layout heights are fully handled
                    for (final delay in [50, 100, 200, 300, 500]) {
                      Future.delayed(Duration(milliseconds: delay), () {
                        if (_scrollController.hasClients) {
                          final newMax = _scrollController.position.maxScrollExtent;
                          _scrollController.jumpTo(newMax);
                        }
                      });
                    }
                  }

                  if (currentCount != _lastMessageCount) {
                    final wasMe = messages.isNotEmpty &&
                        messages.last['sender'].toString().toLowerCase() == widget.currentUsername.toLowerCase();
                    _lastMessageCount = currentCount;

                    // If it is not the very first load, slide smoothly to bottom on new messages if near it
                    if (wasMe || (maxScroll - currentScroll) < 150) {
                      _scrollController.animateTo(
                        maxScroll,
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  } else {
                    // Glide smoothly to bottom if we are near it but not perfectly aligned (e.g. after a reaction height increase)
                    if ((maxScroll - currentScroll) < 150 && (maxScroll - currentScroll) > 1.0) {
                      _scrollController.animateTo(
                        maxScroll,
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  }
                });

                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.black,
                    image: DecorationImage(
                      image: AssetImage('assets/images/chat_bg_dense.png'),
                      fit: BoxFit.cover,
                      opacity: 0.15,
                    ),
                  ),
                  child: Scrollbar(
                    controller: _scrollController,
                    thickness: 4.5,
                    radius: const Radius.circular(2.25),
                    child: ListView(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: ClampingScrollPhysics(),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      children: listItems,
                    ),
                  ),
                );
              },
            ),
            if (_showScrollToBottomBtn)
              Positioned(
                bottom: 12,
                right: 16,
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    _scrollController.animateTo(
                      _scrollController.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                    );
                  },
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black,
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
          // ═══════════════════════════════════════════════════
          // ELEMENT 2: Typing Indicator (Real-time active vibe!)
          // ═══════════════════════════════════════════════════
          if (_isTargetTyping)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 12, top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: widget.avatarColor,
                    backgroundImage: widget.profilePictureUrl.isNotEmpty
                        ? NetworkImage(widget.profilePictureUrl)
                        : null,
                    child: widget.profilePictureUrl.isEmpty
                        ? Text(
                            widget.targetUsername.isNotEmpty
                                ? widget.targetUsername[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF2C2C2E),
                        width: 1.0,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SmoothTypingAnimator(),
                        const SizedBox(width: 8),
                        Text(
                                                          '${widget.targetUsername.toLowerCase()} is typing...',
                          style: const TextStyle(
                            color: Color(0xFF8E8E93),
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          // ELEMENT 3: Premium Simple Bottom Input Bar (Flush edge-to-edge, premium capsule design)
          // ═══════════════════════════════════════════════════
          Builder(
            builder: (context) {
              final bottomPadding = MediaQuery.of(context).padding.bottom;
              if (_isBlocked) {
                if (_blockedBy.toLowerCase() == widget.currentUsername.toLowerCase()) {
                  return Container(
                    margin: EdgeInsets.zero,
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 16,
                      bottom: bottomPadding > 0 ? bottomPadding + 16 : 16,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161618),
                      border: const Border(
                        top: BorderSide(color: Color(0xFF2C2C2E), width: 1.0),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black,
                          blurRadius: 10,
                          spreadRadius: 2,
                          offset: const Offset(0, -4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'You blocked @${widget.targetUsername.toLowerCase()}',
                            style: const TextStyle(color: Colors.white70, fontSize: 14.5),
                          ),
                        ),
                        TextButton(
                          onPressed: _unblockUser,
                          style: TextButton.styleFrom(
                            backgroundColor: const Color(0xFF0A84FF),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Unblock', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5)),
                        ),
                      ],
                    ),
                  );
                } else {
                  return Container(
                    margin: EdgeInsets.zero,
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 24,
                      bottom: bottomPadding > 0 ? bottomPadding + 24 : 24,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161618),
                      border: const Border(
                        top: BorderSide(color: Color(0xFF2C2C2E), width: 1.0),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black,
                          blurRadius: 10,
                          spreadRadius: 2,
                          offset: const Offset(0, -4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'You can no longer message @${widget.targetUsername.toLowerCase()}.',
                      style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14.5, fontStyle: FontStyle.italic),
                    ),
                  );
                }
              }

              Widget buildMoodChips() {
                final moods = [
                  {'name': 'Neutral', 'color': const Color(0xFF8E8E93)},
                  {'name': 'Angry', 'color': const Color(0xFFE53935)},
                  {'name': 'Happy', 'color': const Color(0xFFFBC02D)},
                  {'name': 'Sad', 'color': const Color(0xFF42A5F5)},
                  {'name': 'Tension', 'color': const Color(0xFFFF7043)},
                  {'name': 'Excited', 'color': const Color(0xFFAB47BC)},
                  {'name': 'Chill', 'color': const Color(0xFF66BB6A)},
                ];

                return Container(
                  height: 34,
                  decoration: const BoxDecoration(
                    color: Color(0xFF161618),
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF2C2C2E), width: 0.5),
                    ),
                  ),
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    itemCount: moods.length,
                    itemBuilder: (context, index) {
                      final mood = moods[index];
                      final isSelected = _selectedMood.toLowerCase() == mood['name']!.toString().toLowerCase();
                      final Color moodColor = mood['color'] as Color;

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.0),
                        child: Center(
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedMood = mood['name'] as String;
                              });
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: isSelected ? moodColor.withAlpha(50) : Colors.transparent,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isSelected ? moodColor.withAlpha(80) : Colors.white.withAlpha(20),
                                ),
                              ),
                              child: Text(
                                mood['name'] as String,
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.white.withAlpha(150),
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  fontSize: 12.0,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              }

              return Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF161618),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(220), // Premium upward drop shadow
                      blurRadius: 10,
                      spreadRadius: 2,
                      offset: const Offset(0, -4), // upwards cast shadow
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    buildMoodChips(),
                    Container(
                      margin: EdgeInsets.zero,
                      padding: EdgeInsets.only(
                        left: 6,
                        right: 10,
                        top: 10,
                        bottom: bottomPadding > 0 ? bottomPadding + 10 : 14,
                      ),
                      decoration: const BoxDecoration(
                        color: Color(0xFF161618),
                        border: Border(
                          top: BorderSide(
                            color: Color(0xFF2C2C2E),
                            width: 1.0,
                          ),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.add, color: Color(0xFF0A84FF), size: 26),
                            onPressed: _showAddOptionsSheet,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2C2C2E), // Solid dark capsule
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 0.8,
                                ),
                              ),
                              child: Row(
                                children: [
                                  GestureDetector(
                                    onTap: _showAnimatedEmojiSheet,
                                    child: const Icon(Icons.insert_emoticon, color: Color(0xFF8E8E93), size: 22),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: _messageController,
                                      style: const TextStyle(color: Colors.white, fontSize: 16.0),
                                      textInputAction: TextInputAction.send,
                                      onSubmitted: (_) => _sendMessage(),
                                      autofocus: false,
                                      decoration: const InputDecoration(
                                        hintText: 'Message',
                                        hintStyle: TextStyle(color: Color(0xFF8E8E93), fontSize: 16.0),
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(vertical: 4),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: _showAITransformDialog,
                                    child: const Icon(Icons.auto_awesome, color: Color(0xFFBF5AF2), size: 20),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: _sendMessage,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                color: Color(0xFF0A84FF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.send, color: Colors.white, size: 16),
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
}

  // ═══════════════════════════════════════════════════
  // PREMIUM OPTIONS FUNCTIONALITIES
  // ═══════════════════════════════════════════════════

  void _showContactInfo() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            // Live status variables inside bottom sheet
            final isOnline = _isTargetOnline;
            final email = _targetUserData?['email'] as String? ?? 'No email shared';
            final bio = _targetUserData?['bio'] as String? ?? 'Exploring the digital world on PostMark. 🚀';

            return Container(
              padding: const EdgeInsets.only(left: 20, right: 20, top: 12, bottom: 40),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  // Drag Handle Indicator
                  Container(
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A3A3C),
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // Big Premium Avatar
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: widget.avatarColor,
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: CircleAvatar(
                      radius: 50,
                      backgroundColor: widget.avatarColor,
                      backgroundImage: widget.profilePictureUrl.isNotEmpty
                          ? NetworkImage(widget.profilePictureUrl)
                          : null,
                      child: widget.profilePictureUrl.isEmpty
                          ? Text(
                              widget.targetUsername.isNotEmpty ? widget.targetUsername[0].toUpperCase() : '?',
                              style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // Username
                  Text(
                    widget.targetUsername.toLowerCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  
                  // Pulsing active status row
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _isTargetTyping
                              ? const Color(0xFF0A84FF)
                              : (isOnline ? const Color(0xFF30D158) : Colors.grey),
                          shape: BoxShape.circle,
                          boxShadow: _isTargetTyping
                              ? [
                                  BoxShadow(
                                    color: const Color(0xFF0A84FF),
                                    blurRadius: 6,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : (isOnline
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF30D158),
                                        blurRadius: 6,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isTargetTyping
                            ? 'typing...'
                            : (isOnline ? 'Online' : 'Offline'),
                        style: TextStyle(
                          color: _isTargetTyping
                              ? const Color(0xFF0A84FF)
                              : (isOnline ? const Color(0xFF30D158) : Colors.grey),
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  
                  // Quick Actions Bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildQuickActionItem(
                        icon: _isMuted ? Icons.notifications_off : Icons.notifications_active_outlined,
                        label: _isMuted ? 'Unmute' : 'Mute',
                        color: _isMuted ? const Color(0xFFFF9500) : Colors.white,
                        onTap: () async {
                          HapticFeedback.mediumImpact();
                          await _toggleMuteNotifications();
                          setModalState(() {});
                          setState(() {});
                        },
                      ),
                      _buildQuickActionItem(
                        icon: _isFavourited ? Icons.favorite : Icons.favorite_border,
                        label: _isFavourited ? 'Unfavourite' : 'Favourite',
                        color: _isFavourited ? const Color(0xFFFF2D55) : Colors.white,
                        onTap: () async {
                          HapticFeedback.mediumImpact();
                          await _toggleFavourite();
                          setModalState(() {});
                          setState(() {});
                        },
                      ),
                      _buildQuickActionItem(
                        icon: Icons.block,
                        label: _isBlocked ? 'Unblock' : 'Block',
                        color: _isBlocked ? const Color(0xFF30D158) : const Color(0xFFFF3B30),
                        onTap: () {
                          HapticFeedback.mediumImpact();
                          Navigator.pop(context); // Close contact info sheet
                          if (_isBlocked) {
                            _unblockUser();
                          } else {
                            _showBlockDialog();
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  const Divider(color: Color(0xFF2C2C2E), height: 1),
                  const SizedBox(height: 24),
                  
                  // Details section
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'EMAIL ADDRESS',
                          style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          email,
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                        const SizedBox(height: 24),
                        
                        const Text(
                          'BIO / STATUS',
                          style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          bio,
                          style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
                        ),
                        const SizedBox(height: 24),
                        
                        const Text(
                          'SECURITY & PROTOCOL',
                          style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Messages are secured using encrypted transport protocols over Ably realtime channel streams and Firestore storage.',
                          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

  Widget _buildQuickActionItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF3A3A3C), width: 1),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMuteNotifications() async {
    try {
      final updatedMuted = _isMuted;
      await FirebaseFirestore.instance
          .collection('relationships')
          .doc(_relationshipKey)
          .update({
        'mutedBy': updatedMuted
            ? FieldValue.arrayRemove([widget.currentUsername])
            : FieldValue.arrayUnion([widget.currentUsername]),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updatedMuted ? 'Notifications unmuted' : 'Notifications muted'),
          duration: const Duration(milliseconds: 1500),
        ),
      );
    } catch (_) {}
  }

  Future<void> _toggleFavourite() async {
    try {
      final updatedFav = _isFavourited;
      await FirebaseFirestore.instance
          .collection('relationships')
          .doc(_relationshipKey)
          .update({
        'favouritedBy': updatedFav
            ? FieldValue.arrayRemove([widget.currentUsername])
            : FieldValue.arrayUnion([widget.currentUsername]),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updatedFav ? 'Removed from favourites' : 'Added to favourites'),
          duration: const Duration(milliseconds: 1500),
        ),
      );
    } catch (_) {}
  }

  void _showDisappearingMessagesDialog() {
    final Map<int, String> durations = {
      0: 'Off',
      30: '30 seconds',
      300: '5 minutes',
      3600: '1 hour',
      86400: '24 hours',
    };

    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          title: const Text(
            'Disappearing messages',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2C2C2E)),
          ),
          children: durations.entries.map((entry) {
            final isSelected = _disappearingDuration == entry.key;
            return SimpleDialogOption(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await FirebaseFirestore.instance
                      .collection('chats')
                      .doc(_channelName)
                      .set({
                    'disappearingDuration': entry.key,
                  }, SetOptions(merge: true));
                  
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Disappearing messages set to: ${entry.value}'),
                      duration: const Duration(milliseconds: 1500),
                    ),
                  );
                } catch (_) {}
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      entry.value,
                      style: TextStyle(
                        color: isSelected ? const Color(0xFF0A84FF) : Colors.white,
                        fontSize: 16,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    if (isSelected)
                      const Icon(Icons.check, color: Color(0xFF0A84FF), size: 20),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  void _showReportDialog() {
    final TextEditingController reportController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2C2C2E)),
          ),
          title: const Text('Report User', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: reportController,
            style: const TextStyle(color: Colors.white),
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Enter reason for report...',
              hintStyle: TextStyle(color: Colors.grey),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF2C2C2E))),
              focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF0A84FF))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () async {
                final reason = reportController.text.trim();
                if (reason.isEmpty) return;
                Navigator.pop(context);
                try {
                  await FirebaseFirestore.instance.collection('reports').add({
                    'reporter': widget.currentUsername,
                    'reported': widget.targetUsername,
                    'reason': reason,
                    'timestamp': FieldValue.serverTimestamp(),
                  });
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('User reported. Thank you.'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                } catch (_) {}
              },
              child: const Text('Report', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        );
      },
    );
  }

  void _showBlockDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2C2C2E)),
          ),
          title: const Text('Block User?', style: TextStyle(color: Colors.white)),
          content: Text(
            'Are you sure you want to block @${widget.targetUsername.toLowerCase()}? You will no longer be able to message each other.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context); // Close dialog
                Navigator.pop(context); // Exit ChatPage back to Home
                try {
                  await FirebaseFirestore.instance
                      .collection('relationships')
                      .doc(_relationshipKey)
                      .set({
                    'status': 'blocked',
                    'blockedBy': widget.currentUsername,
                    'updatedAt': FieldValue.serverTimestamp(),
                  }, SetOptions(merge: true));
                  
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Blocked @${widget.targetUsername.toLowerCase()}'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                } catch (_) {}
              },
              child: const Text('Block', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _unblockUser() async {
    try {
      await FirebaseFirestore.instance
          .collection('relationships')
          .doc(_relationshipKey)
          .update({
        'status': 'friends',
        'blockedBy': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unblocked @${widget.targetUsername.toLowerCase()}'),
          duration: const Duration(milliseconds: 1500),
        ),
      );
    } catch (_) {}
  }

  void _showDeleteChatDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2C2C2E)),
          ),
          title: const Text('Delete entire chat?', style: TextStyle(color: Colors.white)),
          content: const Text(
            'This will clear all messages and completely remove this chat from your active chats list.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context); // Close dialog
                Navigator.pop(context); // Exit ChatPage back to Home
                try {
                  // 1. Clear chat for me
                  await _clearChat();
                  
                  // 2. Mark chat as hidden by current user (so they remain friends!)
                  await FirebaseFirestore.instance
                      .collection('relationships')
                      .doc(_relationshipKey)
                      .update({
                    'hiddenBy': FieldValue.arrayUnion([widget.currentUsername.toLowerCase()]),
                  });

                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Chat deleted successfully'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                } catch (_) {}
              },
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFloatingHeaderBar(String lowerTargetName) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Container(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: topPadding > 0 ? topPadding + 4 : 12,
        bottom: 12,
      ),
      decoration: BoxDecoration(
        color: _isSelectMode ? const Color(0xFF1C1C1E) : const Color(0xFF161618),
        border: const Border(
          bottom: BorderSide(
            color: Color(0xFF2C2C2E),
            width: 1.2,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(220), // Premium heavy drop shadow
            blurRadius: 10,
            spreadRadius: 2,
            offset: const Offset(0, 4), // downwards cast shadow
          ),
        ],
      ),
      child: Row(
        children: [
          _isSelectMode
              ? IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 24),
                  onPressed: () {
                    setState(() {
                      _isSelectMode = false;
                      _selectedMessageIds.clear();
                    });
                  },
                )
              : IconButton(
                  icon: const Icon(Icons.chevron_left, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(context),
                ),
          const SizedBox(width: 4),
          Expanded(
            child: _isSelectMode
                ? Text(
                    '${_selectedMessageIds.length} selected',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.normal),
                  )
                : InkWell(
                    onTap: _showContactInfo,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: widget.avatarColor,
                            backgroundImage: widget.profilePictureUrl.isNotEmpty
                                ? NetworkImage(widget.profilePictureUrl)
                                : null,
                            child: widget.profilePictureUrl.isEmpty
                                ? Text(
                                    widget.targetUsername.isNotEmpty
                                        ? widget.targetUsername[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(color: Colors.white, fontSize: 14),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  lowerTargetName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _isTargetTyping
                                      ? 'typing...'
                                      : (_isTargetOnline ? 'online' : 'offline'),
                                  style: TextStyle(
                                    color: _isTargetTyping
                                        ? const Color(0xFF0A84FF)
                                        : (_isTargetOnline ? const Color(0xFF30D158) : Colors.grey),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          if (_isSelectMode) ...[
            if (_selectedMessageIds.isNotEmpty) ...[
              IconButton(
                icon: const Icon(Icons.star, color: Colors.white, size: 22),
                onPressed: _batchStarSelectedMessages,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white, size: 22),
                onPressed: _batchDeleteSelectedMessages,
              ),
              const SizedBox(width: 4),
            ],
          ] else ...[
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white, size: 24),
              color: const Color(0xFF1C1C1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Color(0xFF2C2C2E), width: 1.0),
              ),
              onSelected: (value) {
                if (value == 'contact_info') {
                  _showContactInfo();
                } else if (value == 'select_messages') {
                  setState(() {
                    _isSelectMode = true;
                    _selectedMessageIds.clear();
                  });
                } else if (value == 'mute_notifications') {
                  _toggleMuteNotifications();
                } else if (value == 'disappearing_messages') {
                  _showDisappearingMessagesDialog();
                } else if (value == 'favourites') {
                  _toggleFavourite();
                } else if (value == 'close_chat') {
                  Navigator.pop(context);
                } else if (value == 'report') {
                  _showReportDialog();
                } else if (value == 'block') {
                  _showBlockDialog();
                } else if (value == 'clear_chat') {
                  _clearChat();
                } else if (value == 'delete_chat') {
                  _showDeleteChatDialog();
                }
              },
              itemBuilder: (BuildContext context) {
                return [
                  const PopupMenuItem(
                    value: 'contact_info',
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.white, size: 20),
                        SizedBox(width: 12),
                        Text('Contact info', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'select_messages',
                    child: Row(
                      children: [
                        Icon(Icons.check_box_outlined, color: Colors.white, size: 20),
                        SizedBox(width: 12),
                        Text('Select messages', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'mute_notifications',
                    child: Row(
                      children: [
                        Icon(
                          _isMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(_isMuted ? 'Unmute notifications' : 'Mute notifications', style: const TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'disappearing_messages',
                    child: Row(
                      children: [
                        Icon(Icons.history_toggle_off_outlined, color: Colors.white, size: 20),
                        SizedBox(width: 12),
                        Text('Disappearing messages', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'favourites',
                    child: Row(
                      children: [
                        Icon(
                          _isFavourited ? Icons.favorite : Icons.favorite_border,
                          color: _isFavourited ? Colors.redAccent : Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(_isFavourited ? 'Remove from favourites' : 'Add to favourites', style: const TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'close_chat',
                    child: Row(
                      children: [
                        Icon(Icons.cancel_outlined, color: Colors.white, size: 20),
                        SizedBox(width: 12),
                        Text('Close chat', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(height: 1),
                  const PopupMenuItem(
                    value: 'report',
                    child: Row(
                      children: [
                        Icon(Icons.thumb_down_alt_outlined, color: Colors.redAccent, size: 20),
                        SizedBox(width: 12),
                        Text('Report', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'block',
                    child: Row(
                      children: [
                        Icon(Icons.block, color: Colors.redAccent, size: 20),
                        SizedBox(width: 12),
                        Text('Block', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear_chat',
                    child: Row(
                      children: [
                        Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                        SizedBox(width: 12),
                        Text('Clear chat', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete_chat',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                        SizedBox(width: 12),
                        Text('Delete chat', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ];
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _batchStarSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (var id in _selectedMessageIds) {
        final docRef = FirebaseFirestore.instance
            .collection('chats')
            .doc(_channelName)
            .collection('messages')
            .doc(id);
        batch.update(docRef, {
          'starredBy': FieldValue.arrayUnion([widget.currentUsername])
        });
      }
      await batch.commit();
      
      setState(() {
        _isSelectMode = false;
        _selectedMessageIds.clear();
      });
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selected messages starred'),
          duration: Duration(milliseconds: 1500),
        ),
      );
    } catch (_) {}
  }

  Future<void> _batchDeleteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (var id in _selectedMessageIds) {
        final docRef = FirebaseFirestore.instance
            .collection('chats')
            .doc(_channelName)
            .collection('messages')
            .doc(id);
        batch.update(docRef, {
          'deletedFor': FieldValue.arrayUnion([widget.currentUsername])
        });
      }
      await batch.commit();
      
      setState(() {
        _isSelectMode = false;
        _selectedMessageIds.clear();
      });
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selected messages deleted for me'),
          duration: Duration(milliseconds: 1500),
        ),
      );
    } catch (_) {}
  }

  Future<void> _deleteMessageFromDisappearing(String messageId) async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_channelName)
          .collection('messages')
          .doc(messageId)
          .delete();
    } catch (_) {}
  }
}

class SmoothTypingAnimator extends StatefulWidget {
  const SmoothTypingAnimator({super.key});

  @override
  State<SmoothTypingAnimator> createState() => _SmoothTypingAnimatorState();
}

class _SmoothTypingAnimatorState extends State<SmoothTypingAnimator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildDot(int index, double value) {
    // Staggered delay for each dot to create a smooth wave/fluid effect
    final double delay = index * (pi / 3.5);
    final double animValue = sin(value * 2 * pi - delay);
    
    // Bouncing calculation (-3.5px to 0px bounce upward)
    final double bounce = animValue * 3.5;
    
    // Scaling calculation (0.95 to 1.15 scale)
    final double scale = 0.95 + 0.15 * animValue;
    
    // Opacity calculation (0.6 to 1.0 opacity)
    final double opacity = 0.6 + 0.4 * animValue;

    // Harmonious colors forming a fluid Apple Blue -> Purple -> Apple Red transition
    final colors = [
      const Color(0xFF0A84FF), // Dot 1: blue
      const Color(0xFF985EFF), // Dot 2: purple
      const Color(0xFFFF453A), // Dot 3: red
    ];

    final color = colors[index];

    return Transform.translate(
      offset: Offset(0, -bounce.abs()), // Move up
      child: Transform.scale(
        scale: scale,
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color,
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
                BoxShadow(
                  color: Colors.white,
                  blurRadius: 2,
                  spreadRadius: 0.2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDot(0, _controller.value),
              const SizedBox(width: 5),
              _buildDot(1, _controller.value),
              const SizedBox(width: 5),
              _buildDot(2, _controller.value),
            ],
          ),
        );
      },
    );
  }
}

class WhatsAppScrollPhysics extends BouncingScrollPhysics {
  const WhatsAppScrollPhysics({super.parent});

  @override
  WhatsAppScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return WhatsAppScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // Solid heavily-weighted "machinery" dampening factor for dragging (85% transfer delta)
    return super.applyPhysicsToUserOffset(position, offset * 0.85);
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    // Premium deceleration dampening factor for momentum scrolling (55% inertia)
    final dampenedVelocity = velocity * 0.55;
    return super.createBallisticSimulation(position, dampenedVelocity);
  }
}

class HinduTraditionalDoodlePainter extends CustomPainter {
  const HinduTraditionalDoodlePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(22) // Soft watermark opacity for main motifs
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final vinePaint = Paint()
      ..color = Colors.white.withAlpha(15) // Soft secondary opacity for creeping vines
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;

    final leafPaint = Paint()
      ..color = Colors.white.withAlpha(15) // Soft secondary opacity for leaves
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    final fillPaint = Paint()
      ..color = Colors.white.withAlpha(22) // Soft opacity for filled accents
      ..style = PaintingStyle.fill;

    const double cellSize = 240.0; // Perfect cell size for dense traditional print
    final int cols = (size.width / cellSize).ceil();
    final int rows = (size.height / cellSize).ceil();

    for (int i = 0; i < cols; i++) {
      for (int j = 0; j < rows; j++) {
        canvas.save();
        canvas.translate(i * cellSize, j * cellSize);

        // ═══════════════════════════════════════════════════
        // 1. Continuous Organic Winding Creepers (Vines & Leaves)
        // ═══════════════════════════════════════════════════
        
        // Vine 1: Horizontal top wave (0,80) to (240,80)
        _drawVineWithLeaves(
          canvas,
          vinePaint,
          leafPaint,
          [const Offset(0, 80), const Offset(60, 20), const Offset(180, 140), const Offset(240, 80)],
          true,
        );

        // Vine 2: Horizontal bottom wave (240,160) to (0,160)
        _drawVineWithLeaves(
          canvas,
          vinePaint,
          leafPaint,
          [const Offset(240, 160), const Offset(180, 220), const Offset(60, 100), const Offset(0, 160)],
          true,
        );

        // Vine 3: Vertical left wave (80,0) to (80,240)
        _drawVineWithLeaves(
          canvas,
          vinePaint,
          leafPaint,
          [const Offset(80, 0), const Offset(20, 60), const Offset(140, 180), const Offset(80, 240)],
          true,
        );

        // Vine 4: Vertical right wave (160,240) to (160,0)
        _drawVineWithLeaves(
          canvas,
          vinePaint,
          leafPaint,
          [const Offset(160, 240), const Offset(220, 180), const Offset(100, 60), const Offset(160, 0)],
          true,
        );

        // ═══════════════════════════════════════════════════
        // 2. Scattered Traditional Hindu Motifs
        // ═══════════════════════════════════════════════════
        
        // Ganesha in Arch at (60, 120)
        _drawGaneshaInArch(canvas, paint, fillPaint, 60, 120);

        // Kalash at (180, 120)
        _drawKalash(canvas, paint, fillPaint, 180, 120);

        // Om (ॐ) at (60, 40)
        _drawOm(canvas, paint, fillPaint, 60, 40);

        // Trishula at (180, 40)
        _drawTrishula(canvas, paint, 180, 40);

        // Lotus at (120, 195)
        _drawLotus(canvas, paint, 120, 195);

        // Diya at (120, 70)
        _drawDiya(canvas, paint, fillPaint, 120, 70);

        // ═══════════════════════════════════════════════════
        // 3. Extra Gap Fillers (Flowers & Dots)
        // ═══════════════════════════════════════════════════
        
        // Small flowers in remaining pockets
        _drawFlower(canvas, paint, const Offset(30, 200), 7.0);
        _drawFlower(canvas, paint, const Offset(210, 200), 7.0);
        _drawFlower(canvas, paint, const Offset(120, 120), 7.0);
        _drawFlower(canvas, paint, const Offset(30, 80), 7.0);
        _drawFlower(canvas, paint, const Offset(210, 80), 7.0);

        // Tiny border/corner dots
        canvas.drawCircle(const Offset(10, 10), 1.2, fillPaint);
        canvas.drawCircle(const Offset(230, 10), 1.2, fillPaint);
        canvas.drawCircle(const Offset(10, 230), 1.2, fillPaint);
        canvas.drawCircle(const Offset(230, 230), 1.2, fillPaint);
        canvas.drawCircle(const Offset(120, 20), 1.2, fillPaint);
        canvas.drawCircle(const Offset(120, 220), 1.2, fillPaint);

        canvas.restore();
      }
    }
  }

  // Bezier evaluation and tangent helpers
  Offset _evaluateQuadratic(Offset p0, Offset p1, Offset p2, double t) {
    final double u = 1 - t;
    final double tt = t * t;
    final double uu = u * u;
    final double x = uu * p0.dx + 2 * u * t * p1.dx + tt * p2.dx;
    final double y = uu * p0.dy + 2 * u * t * p1.dy + tt * p2.dy;
    return Offset(x, y);
  }

  Offset _tangentQuadratic(Offset p0, Offset p1, Offset p2, double t) {
    final double x = 2 * (1 - t) * (p1.dx - p0.dx) + 2 * t * (p2.dx - p1.dx);
    final double y = 2 * (1 - t) * (p1.dy - p0.dy) + 2 * t * (p2.dy - p1.dy);
    return Offset(x, y);
  }

  Offset _evaluateCubic(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final double u = 1 - t;
    final double tt = t * t;
    final double uu = u * u;
    final double uuu = uu * u;
    final double ttt = tt * t;
    final double x = uuu * p0.dx + 3 * uu * t * p1.dx + 3 * u * tt * p2.dx + ttt * p3.dx;
    final double y = uuu * p0.dy + 3 * uu * t * p1.dy + 3 * u * tt * p2.dy + ttt * p3.dy;
    return Offset(x, y);
  }

  Offset _tangentCubic(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final double u = 1 - t;
    final double x = 3 * u * u * (p1.dx - p0.dx) + 6 * u * t * (p2.dx - p1.dx) + 3 * t * t * (p3.dx - p2.dx);
    final double y = 3 * u * u * (p1.dy - p0.dy) + 6 * u * t * (p2.dy - p1.dy) + 3 * t * t * (p3.dy - p2.dy);
    return Offset(x, y);
  }

  // Drawing helper methods
  void _drawLeaf(Canvas canvas, Paint paint, Offset base, double angle, double scale) {
    canvas.save();
    canvas.translate(base.dx, base.dy);
    canvas.rotate(angle);
    canvas.scale(scale);

    final Path leaf = Path();
    leaf.moveTo(0, 0);
    leaf.cubicTo(6, -12, 14, -12, 0, -32);
    leaf.cubicTo(-14, -12, -6, -12, 0, 0);

    // Center dividing vein
    leaf.moveTo(0, 0);
    leaf.lineTo(0, -28);

    // Side veins
    leaf.moveTo(0, -8);
    leaf.lineTo(4, -11);
    leaf.moveTo(0, -8);
    leaf.lineTo(-4, -11);

    leaf.moveTo(0, -16);
    leaf.lineTo(3, -19);
    leaf.moveTo(0, -16);
    leaf.lineTo(-3, -19);

    canvas.drawPath(leaf, paint);
    canvas.restore();
  }

  void _drawTendril(Canvas canvas, Paint paint, Offset base, double angle, double scale) {
    canvas.save();
    canvas.translate(base.dx, base.dy);
    canvas.rotate(angle);
    canvas.scale(scale);

    final Path tendril = Path();
    tendril.moveTo(0, 0);
    tendril.cubicTo(12, -12, 22, 2, 16, 16);
    tendril.cubicTo(10, 26, -4, 16, 0, 6);
    tendril.cubicTo(3, 0, 10, 6, 8, 10);

    canvas.drawPath(tendril, paint);
    canvas.restore();
  }

  void _drawFlower(Canvas canvas, Paint paint, Offset center, double radius) {
    canvas.drawCircle(center, radius * 0.28, paint);
    for (int k = 0; k < 5; k++) {
      final double angle = k * 2 * pi / 5;
      final double px = center.dx + radius * 0.65 * cos(angle);
      final double py = center.dy + radius * 0.65 * sin(angle);
      canvas.drawCircle(Offset(px, py), radius * 0.32, paint);
    }
  }

  void _drawVineWithLeaves(Canvas canvas, Paint vinePaint, Paint leafPaint, List<Offset> points, bool isCubic) {
    final Path path = Path();
    path.moveTo(points[0].dx, points[0].dy);
    if (isCubic) {
      path.cubicTo(points[1].dx, points[1].dy, points[2].dx, points[2].dy, points[3].dx, points[3].dy);
    } else {
      path.quadraticBezierTo(points[1].dx, points[1].dy, points[2].dx, points[2].dy);
    }
    canvas.drawPath(path, vinePaint);

    final List<double> ts = [0.15, 0.35, 0.55, 0.75, 0.95];
    for (int k = 0; k < ts.length; k++) {
      final double t = ts[k];
      final Offset pos = isCubic
          ? _evaluateCubic(points[0], points[1], points[2], points[3], t)
          : _evaluateQuadratic(points[0], points[1], points[2], t);

      final Offset tan = isCubic
          ? _tangentCubic(points[0], points[1], points[2], points[3], t)
          : _tangentQuadratic(points[0], points[1], points[2], t);

      final double angle = atan2(tan.dy, tan.dx);
      final double offsetAngle = (k % 2 == 0) ? (pi / 2.2) : (-pi / 2.2);

      _drawLeaf(canvas, leafPaint, pos, angle + offsetAngle, 0.45);

      if (k == 2) {
        _drawTendril(canvas, leafPaint, pos, angle - offsetAngle, 0.4);
      }
    }
  }

  void _drawGaneshaInArch(Canvas canvas, Paint paint, Paint fillPaint, double ax, double ay) {
    // 1. Pointed Arch
    final Path arch = Path();
    arch.moveTo(ax - 22, ay + 35);
    arch.lineTo(ax - 22, ay - 5);
    arch.cubicTo(ax - 22, ay - 28, ax - 10, ay - 38, ax, ay - 44);
    arch.cubicTo(ax + 10, ay - 38, ax + 22, ay - 28, ax + 22, ay - 5);
    arch.lineTo(ax + 22, ay + 35);
    canvas.drawPath(arch, paint);

    // Outer decorative arch
    final Path outerArch = Path();
    outerArch.moveTo(ax - 26, ay + 35);
    outerArch.lineTo(ax - 26, ay - 5);
    outerArch.cubicTo(ax - 26, ay - 32, ax - 12, ay - 43, ax, ay - 49);
    outerArch.cubicTo(ax + 12, ay - 43, ax + 26, ay - 32, ax + 26, ay - 5);
    outerArch.lineTo(ax + 26, ay + 35);
    canvas.drawPath(outerArch, paint);

    // Arch scallops/leaves
    for (double t = 0.0; t <= 1.0; t += 0.2) {
      final Offset p = _evaluateCubic(
        Offset(ax - 26, ay - 5),
        Offset(ax - 26, ay - 32),
        Offset(ax - 12, ay - 43),
        Offset(ax, ay - 49),
        t,
      );
      canvas.drawCircle(p, 1.8, paint);

      final Offset pr = _evaluateCubic(
        Offset(ax + 26, ay - 5),
        Offset(ax + 26, ay - 32),
        Offset(ax + 12, ay - 43),
        Offset(ax, ay - 49),
        t,
      );
      canvas.drawCircle(pr, 1.8, paint);
    }

    // 2. Ganesha silhouette (centered at ax, ay + 2)
    final double gx = ax;
    final double gy = ay + 2;
    final Path ganesha = Path();
    // Mukut (Crown)
    ganesha.moveTo(gx - 5, gy - 20);
    ganesha.lineTo(gx, gy - 28);
    ganesha.lineTo(gx + 5, gy - 20);
    ganesha.close();

    ganesha.moveTo(gx - 4, gy - 22); ganesha.lineTo(gx + 4, gy - 22);
    ganesha.moveTo(gx - 3, gy - 25); ganesha.lineTo(gx + 3, gy - 25);

    // Ears
    ganesha.moveTo(gx - 4, gy - 20);
    ganesha.cubicTo(gx - 13, gy - 20, gx - 11, gy - 10, gx - 4, gy - 7);
    ganesha.moveTo(gx + 4, gy - 20);
    ganesha.cubicTo(gx + 13, gy - 20, gx + 11, gy - 10, gx + 4, gy - 7);

    // Face
    ganesha.moveTo(gx - 4, gy - 12);
    ganesha.lineTo(gx + 4, gy - 12);

    // Trunk
    ganesha.moveTo(gx, gy - 12);
    ganesha.cubicTo(gx + 2, gy - 3, gx - 7, gy - 2, gx - 7, gy - 8);
    ganesha.cubicTo(gx - 7, gy - 11, gx - 4, gy - 10, gx - 4, gy - 8);

    // Body
    ganesha.moveTo(gx - 4, gy - 7);
    ganesha.quadraticBezierTo(gx - 9, gy + 2, gx - 6, gy + 10);
    ganesha.moveTo(gx + 4, gy - 7);
    ganesha.quadraticBezierTo(gx + 9, gy, gx + 7, gy + 5);

    ganesha.moveTo(gx - 5, gy + 2);
    ganesha.quadraticBezierTo(gx, gy + 13, gx + 5, gy + 2);

    ganesha.moveTo(gx - 8, gy + 11);
    ganesha.quadraticBezierTo(gx, gy + 15, gx + 8, gy + 11);
    ganesha.quadraticBezierTo(gx, gy + 9, gx - 8, gy + 11);

    canvas.drawPath(ganesha, paint);
    canvas.drawCircle(Offset(gx, gy - 16), 1.0, fillPaint);
  }

  void _drawKalash(Canvas canvas, Paint paint, Paint fillPaint, double kx, double ky) {
    final Path kalash = Path();
        final double kyBase = ky + 20;
    // Pot base
    kalash.moveTo(kx - 10, kyBase);
    kalash.lineTo(kx + 10, kyBase);
    // Pot body
    kalash.cubicTo(kx + 22, kyBase - 5, kx + 20, ky - 5, kx + 12, ky - 10);
    // Neck
    kalash.lineTo(kx - 12, ky - 10);
    kalash.cubicTo(kx - 20, ky - 5, kx - 22, kyBase - 5, kx - 10, kyBase);

    // Flared rim
    kalash.moveTo(kx - 14, ky - 10);
    kalash.lineTo(kx + 14, ky - 10);
    kalash.lineTo(kx + 16, ky - 14);
    kalash.lineTo(kx - 16, ky - 14);
    kalash.close();

    canvas.drawPath(kalash, paint);

    // Hatching bands
    final Path lines = Path();
    lines.moveTo(kx - 17, ky + 4);
    lines.quadraticBezierTo(kx, ky + 7, kx + 17, ky + 4);
    lines.moveTo(kx - 18, ky + 8);
    lines.quadraticBezierTo(kx, ky + 11, kx + 18, ky + 8);

    for (int m = -12; m <= 12; m += 6) {
      lines.moveTo(kx + m - 3, ky + 4);
      lines.lineTo(kx + m + 3, ky + 8);
      lines.moveTo(kx + m + 3, ky + 4);
      lines.lineTo(kx + m - 3, ky + 8);
    }
    canvas.drawPath(lines, paint);

    // Leaves
    final Path leaves = Path();
    leaves.moveTo(kx - 12, ky - 14);
    leaves.cubicTo(kx - 22, ky - 20, kx - 12, ky - 26, kx - 4, ky - 16);
    leaves.moveTo(kx + 12, ky - 14);
    leaves.cubicTo(kx + 22, ky - 20, kx + 12, ky - 26, kx + 4, ky - 16);
    leaves.moveTo(kx - 5, ky - 14);
    leaves.cubicTo(kx - 8, ky - 30, kx + 8, ky - 30, kx + 5, ky - 14);
    canvas.drawPath(leaves, paint);

    // Coconut
    final Path coconut = Path();
    coconut.moveTo(kx - 5, ky - 16);
    coconut.cubicTo(kx - 9, ky - 25, kx, ky - 34, kx, ky - 36);
    coconut.cubicTo(kx, ky - 34, kx + 9, ky - 25, kx + 5, ky - 16);
    canvas.drawPath(coconut, paint);

    final Path cocoLines = Path();
    cocoLines.moveTo(kx - 2, ky - 20);
    cocoLines.quadraticBezierTo(kx, ky - 28, kx, ky - 32);
    canvas.drawPath(cocoLines, paint);
  }

  void _drawOm(Canvas canvas, Paint paint, Paint fillPaint, double ox, double oy) {
    final Path om = Path();
    om.moveTo(ox - 12, oy - 4);
    om.cubicTo(ox - 20, oy - 12, ox - 2, oy - 16, ox, oy - 4);
    om.cubicTo(ox + 2, oy + 4, ox - 16, oy + 12, ox - 4, oy + 14);
    om.cubicTo(ox + 4, oy + 15, ox + 9, oy + 9, ox + 9, oy + 3);
    om.moveTo(ox, oy - 4);
    om.quadraticBezierTo(ox + 10, oy - 1, ox + 16, oy + 10);
    om.moveTo(ox - 6, oy - 11);
    om.quadraticBezierTo(ox, oy - 8, ox + 6, oy - 11);
    canvas.drawPath(om, paint);
    canvas.drawCircle(Offset(ox, oy - 15), 1.5, fillPaint);
  }

  void _drawLotus(Canvas canvas, Paint paint, double lx, double ly) {
    final Path lotus = Path();
    lotus.moveTo(lx, ly - 15);
    lotus.quadraticBezierTo(lx - 7, ly - 3, lx, ly + 11);
    lotus.quadraticBezierTo(lx + 7, ly - 3, lx, ly - 15);

    lotus.moveTo(lx, ly - 7);
    lotus.quadraticBezierTo(lx - 15, ly - 11, lx - 13, ly + 5);
    lotus.quadraticBezierTo(lx - 5, ly + 9, lx, ly + 11);

    lotus.moveTo(lx, ly - 7);
    lotus.quadraticBezierTo(lx + 15, ly - 11, lx + 13, ly + 5);
    lotus.quadraticBezierTo(lx + 5, ly + 9, lx, ly + 11);

    lotus.moveTo(lx - 7, ly + 5);
    lotus.quadraticBezierTo(lx - 20, ly + 3, lx - 16, ly + 13);
    lotus.quadraticBezierTo(lx - 7, ly + 11, lx - 2, ly + 11);

    lotus.moveTo(lx + 7, ly + 5);
    lotus.quadraticBezierTo(lx + 20, ly + 3, lx + 16, ly + 13);
    lotus.quadraticBezierTo(lx + 7, ly + 11, lx + 2, ly + 11);

    lotus.moveTo(lx - 7, ly + 11);
    lotus.quadraticBezierTo(lx, ly + 15, lx + 7, ly + 11);

    canvas.drawPath(lotus, paint);
  }

  void _drawDiya(Canvas canvas, Paint paint, Paint fillPaint, double dx, double dy) {
    final Path diya = Path();
    diya.moveTo(dx - 16, dy + 2);
    diya.quadraticBezierTo(dx - 18, dy + 11, dx, dy + 13);
    diya.quadraticBezierTo(dx + 18, dy + 11, dx + 16, dy + 2);
    diya.quadraticBezierTo(dx, dy + 5, dx - 16, dy + 2);

    diya.moveTo(dx - 14, dy + 4);
    diya.quadraticBezierTo(dx - 16, dy + 9, dx, dy + 11);
    diya.quadraticBezierTo(dx + 16, dy + 9, dx + 14, dy + 4);

    diya.moveTo(dx, dy - 2);
    diya.quadraticBezierTo(dx - 5, dy - 8, dx, dy - 17);
    diya.quadraticBezierTo(dx + 5, dy - 8, dx, dy - 2);

    diya.moveTo(dx, dy - 5);
    diya.quadraticBezierTo(dx - 2.5, dy - 9, dx, dy - 13);
    diya.quadraticBezierTo(dx + 2.5, dy - 9, dx, dy - 5);

    canvas.drawPath(diya, paint);
  }

  void _drawTrishula(Canvas canvas, Paint paint, double tx, double ty) {
    final Path trishula = Path();
    trishula.moveTo(tx, ty + 16);
    trishula.lineTo(tx, ty - 16);

    trishula.moveTo(tx, ty - 1);
    trishula.cubicTo(tx - 11, ty - 1, tx - 11, ty - 11, tx - 7, ty - 13);
    trishula.cubicTo(tx - 5, ty - 11, tx - 7, ty - 2, tx, ty - 1);

    trishula.moveTo(tx, ty - 1);
    trishula.cubicTo(tx + 11, ty - 1, tx + 11, ty - 11, tx + 7, ty - 13);
    trishula.cubicTo(tx + 5, ty - 11, tx + 7, ty - 2, tx, ty - 1);

    trishula.moveTo(tx - 5, ty + 3);
    trishula.lineTo(tx + 5, ty + 3);
    trishula.lineTo(tx - 5, ty + 7);
    trishula.lineTo(tx + 5, ty + 7);
    trishula.close();

    canvas.drawPath(trishula, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class MapMockupPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Draw subtle grid lines
    final gridPaint = Paint()
      ..color = Colors.white.withAlpha(20)
      ..strokeWidth = 0.8;
    
    for (double i = 0; i < size.width; i += 20) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), gridPaint);
    }
    for (double j = 0; j < size.height; j += 20) {
      canvas.drawLine(Offset(0, j), Offset(size.width, j), gridPaint);
    }

    // Draw organic river/lake shapes
    final waterPaint = Paint()
      ..color = const Color(0xFF007AFF).withAlpha(40)
      ..style = PaintingStyle.fill;
    final waterPath = Path()
      ..moveTo(0, size.height * 0.85)
      ..quadraticBezierTo(size.width * 0.35, size.height * 0.65, size.width, size.height * 0.9)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(waterPath, waterPaint);

    // Draw styled green park areas
    final parkPaint = Paint()
      ..color = const Color(0xFF30D158).withAlpha(25)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(12, 12, size.width * 0.25, size.height * 0.35),
        const Radius.circular(8),
      ),
      parkPaint,
    );

    // Draw primary roads/routes
    final roadPaint = Paint()
      ..color = Colors.white.withAlpha(60)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, size.height * 0.45), Offset(size.width, size.height * 0.5), roadPaint);

    // Draw secondary curved roads
    final secondaryRoadPaint = Paint()
      ..color = Colors.white.withAlpha(40)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final avenuePath = Path()
      ..moveTo(size.width * 0.25, 0)
      ..quadraticBezierTo(size.width * 0.3, size.height * 0.45, size.width * 0.85, size.height);
    canvas.drawPath(avenuePath, secondaryRoadPaint);

    // Draw route navigation overlay line
    final routePaint = Paint()
      ..color = const Color(0xFF0A84FF).withAlpha(180)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final routePath = Path()
      ..moveTo(size.width * 0.5, size.height)
      ..lineTo(size.width * 0.5, size.height * 0.5)
      ..quadraticBezierTo(size.width * 0.5, size.height * 0.45, size.width * 0.4, size.height * 0.45);
    canvas.drawPath(routePath, routePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PulsingLiveMarker extends StatefulWidget {
  const PulsingLiveMarker({super.key});

  @override
  State<PulsingLiveMarker> createState() => _PulsingLiveMarkerState();
}

class _PulsingLiveMarkerState extends State<PulsingLiveMarker> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Container(
              width: 16 + 24 * _controller.value,
              height: 16 + 24 * _controller.value,
              decoration: BoxDecoration(
                color: const Color(0xFF34A853).withAlpha((255 * (1.0 - _controller.value)).toInt()),
                shape: BoxShape.circle,
              ),
            );
          },
        ),
        const Icon(Icons.location_on, color: Color(0xFF34A853), size: 36),
      ],
    );
  }
}

class FullScreenVideoViewer extends StatefulWidget {
  final String videoPath;
  final bool isFile;
  final String sender;
  final dynamic timestamp;
  final String fileName;
  final String heroTag;

  const FullScreenVideoViewer({
    super.key,
    required this.videoPath,
    required this.isFile,
    required this.sender,
    required this.timestamp,
    required this.fileName,
    required this.heroTag,
  });

  @override
  State<FullScreenVideoViewer> createState() => _FullScreenVideoViewerState();
}

class _FullScreenVideoViewerState extends State<FullScreenVideoViewer> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _showControls = true;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    if (widget.isFile) {
      _controller = VideoPlayerController.file(File(widget.videoPath));
    } else {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoPath));
    }

    _controller.initialize().then((_) {
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
        _controller.play();
        _startControlsTimer();
      }
    }).catchError((error) {
      debugPrint('Video initialization failed: $error');
    });

    _controller.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _togglePlay() {
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
        _startControlsTimer();
      } else {
        _controller.play();
        _resetControlsTimer();
      }
    });
  }

  void _startControlsTimer() {
    _controlsTimer?.cancel();
    if (_controller.value.isPlaying) {
      _controlsTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _showControls = false;
          });
        }
      });
    }
  }

  void _resetControlsTimer() {
    setState(() {
      _showControls = true;
    });
    _startControlsTimer();
  }

  @override
  Widget build(BuildContext context) {
    String formattedTime = 'Recent';
    if (widget.timestamp != null) {
      try {
        if (widget.timestamp is Timestamp) {
          formattedTime = DateFormat('MMM d, h:mm a').format(widget.timestamp.toDate().toLocal());
        } else if (widget.timestamp is DateTime) {
          formattedTime = DateFormat('MMM d, h:mm a').format(widget.timestamp.toLocal());
        }
      } catch (_) {}
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Dismissible(
        key: Key(widget.heroTag),
        direction: DismissDirection.vertical,
        onDismissed: (direction) => Navigator.pop(context),
        child: Container(
          color: Colors.black,
          width: double.infinity,
          height: double.infinity,
          child: Stack(
            children: [
              Center(
                child: _isInitialized
                    ? GestureDetector(
                        onTap: _resetControlsTimer,
                        child: Hero(
                          tag: widget.heroTag,
                          child: AspectRatio(
                            aspectRatio: _controller.value.aspectRatio,
                            child: VideoPlayer(_controller),
                          ),
                        ),
                      )
                    : const CircularProgressIndicator(color: Color(0xFF0A84FF)),
              ),
              if (_showControls || !_controller.value.isPlaying)
                Positioned.fill(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black54],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.0, 0.2, 0.8, 1.0],
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                            child: Row(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                                  onPressed: () => Navigator.pop(context),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        widget.sender,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          fontFamily: 'Plus Jakarta Sans',
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${widget.fileName} • $formattedTime',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                          fontFamily: 'Plus Jakarta Sans',
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Center(
                          child: IconButton(
                            icon: Icon(
                              _controller.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                              color: Colors.white,
                              size: 72,
                            ),
                            onPressed: _togglePlay,
                          ),
                        ),
                        SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_isInitialized)
                                  VideoProgressIndicator(
                                    _controller,
                                    allowScrubbing: true,
                                    colors: const VideoProgressColors(
                                      playedColor: Color(0xFF0A84FF),
                                      bufferedColor: Colors.white24,
                                      backgroundColor: Colors.white10,
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _formatDuration(_controller.value.position),
                                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                                    ),
                                    Text(
                                      _formatDuration(_controller.value.duration),
                                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}

class FullScreenImageViewer extends StatelessWidget {
  final String imagePath;
  final bool isFile;
  final String sender;
  final dynamic timestamp;
  final String fileName;
  final String heroTag;

  const FullScreenImageViewer({
    super.key,
    required this.imagePath,
    required this.isFile,
    required this.sender,
    required this.timestamp,
    required this.fileName,
    required this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    String formattedTime = 'Recent';
    if (timestamp != null) {
      try {
        if (timestamp is Timestamp) {
          formattedTime = DateFormat('MMM d, h:mm a').format(timestamp.toDate().toLocal());
        } else if (timestamp is DateTime) {
          formattedTime = DateFormat('MMM d, h:mm a').format(timestamp.toLocal());
        }
      } catch (_) {}
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Dismissible(
        key: Key(heroTag),
        direction: DismissDirection.vertical,
        onDismissed: (direction) => Navigator.pop(context),
        child: Container(
          color: Colors.black,
          width: double.infinity,
          height: double.infinity,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  panEnabled: true,
                  boundaryMargin: const EdgeInsets.all(20),
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: Hero(
                    tag: heroTag,
                    child: isFile
                        ? Image.file(
                            File(imagePath),
                            errorBuilder: (c, e, s) => const Icon(Icons.broken_image, color: Colors.grey, size: 50),
                          )
                        : Image.network(
                            imagePath,
                            errorBuilder: (c, e, s) => const Icon(Icons.broken_image, color: Colors.grey, size: 50),
                          ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.black54, Colors.transparent],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                            onPressed: () => Navigator.pop(context),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  sender,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Plus Jakarta Sans',
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${fileName.isEmpty ? "Photo" : fileName} • $formattedTime',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontFamily: 'Plus Jakarta Sans',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FullScreenTextViewer extends StatefulWidget {
  final String filePath;
  final String sender;
  final dynamic timestamp;
  final String fileName;
  final String heroTag;

  const FullScreenTextViewer({
    super.key,
    required this.filePath,
    required this.sender,
    required this.timestamp,
    required this.fileName,
    required this.heroTag,
  });

  @override
  State<FullScreenTextViewer> createState() => _FullScreenTextViewerState();
}

class _FullScreenTextViewerState extends State<FullScreenTextViewer> {
  String _fileContent = 'Loading...';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    try {
      final file = File(widget.filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (mounted) {
          setState(() {
            _fileContent = content;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _fileContent = 'Error: Local file not found.';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _fileContent = 'Error reading file: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String formattedTime = 'Recent';
    if (widget.timestamp != null) {
      try {
        if (widget.timestamp is Timestamp) {
          formattedTime = DateFormat('MMM d, h:mm a').format(widget.timestamp.toDate().toLocal());
        } else if (widget.timestamp is DateTime) {
          formattedTime = DateFormat('MMM d, h:mm a').format(widget.timestamp.toLocal());
        }
      } catch (_) {}
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Hero(
          tag: widget.heroTag,
          child: Material(
            color: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.fileName,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Sent by ${widget.sender} • $formattedTime',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF0A84FF)))
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: SelectionArea(
                  child: Text(
                    _fileContent,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

// PREMIUM LOCAL DEVICE MEDIA VAULT PAGE
class DeviceVaultPage extends StatefulWidget {
  const DeviceVaultPage({super.key});

  @override
  State<DeviceVaultPage> createState() => _DeviceVaultPageState();
}

class _DeviceVaultPageState extends State<DeviceVaultPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoading = true;
  List<File> _images = [];
  List<File> _videos = [];
  List<File> _audio = [];
  List<File> _documents = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadLocalFiles();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadLocalFiles() async {
    try {
      Directory? targetDirectory;
      if (Platform.isWindows) {
        final docsDir = await getApplicationDocumentsDirectory();
        targetDirectory = Directory('${docsDir.path}/PostMark Media');
      } else if (Platform.isAndroid) {
        targetDirectory = Directory('/storage/emulated/0/Download/PostMark Media');
        if (!await targetDirectory.exists()) {
          targetDirectory = Directory('/storage/emulated/0/Documents/PostMark Media');
        }
        if (!await targetDirectory.exists()) {
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            targetDirectory = Directory('${externalDir.path}/PostMark Media');
          }
        }
      } else {
        final appDocDir = await getApplicationDocumentsDirectory();
        targetDirectory = Directory('${appDocDir.path}/PostMark Media');
      }

      if (await targetDirectory.exists()) {
        final List<FileSystemEntity> entities = await targetDirectory.list().toList();
        final List<File> files = entities.whereType<File>().toList();

        // Sort by modified date descending
        files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

        final List<File> imageFiles = [];
        final List<File> videoFiles = [];
        final List<File> audioFiles = [];
        final List<File> docFiles = [];

        for (final file in files) {
          final path = file.path.toLowerCase();
          if (path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.png') || path.endsWith('.gif') || path.endsWith('.webp') || path.endsWith('.bmp')) {
            imageFiles.add(file);
          } else if (path.endsWith('.mp4') || path.endsWith('.mov') || path.endsWith('.avi') || path.endsWith('.mkv') || path.endsWith('.3gp') || path.endsWith('.webm')) {
            videoFiles.add(file);
          } else if (path.endsWith('.mp3') || path.endsWith('.m4a') || path.endsWith('.wav') || path.endsWith('.aac') || path.endsWith('.ogg') || path.endsWith('.flac')) {
            audioFiles.add(file);
          } else {
            docFiles.add(file);
          }
        }

        if (mounted) {
          setState(() {
            _images = imageFiles;
            _videos = videoFiles;
            _audio = audioFiles;
            _documents = docFiles;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading vault files: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _getFileSizeString(File file) {
    try {
      final bytes = file.lengthSync();
      if (bytes < 1024) return '$bytes B';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return 'Unknown Size';
    }
  }

  void _openImage(File file) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.5),
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) => FullScreenImageViewer(
          imagePath: file.path,
          isFile: true,
          sender: 'Local Device',
          timestamp: file.lastModifiedSync(),
          fileName: file.path.split('/').last.split('\\').last,
          heroTag: 'vault_image_${file.path.hashCode}',
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  void _openVideo(File file) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.5),
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) => FullScreenVideoViewer(
          videoPath: file.path,
          isFile: true,
          sender: 'Local Device',
          timestamp: file.lastModifiedSync(),
          fileName: file.path.split('/').last.split('\\').last,
          heroTag: 'vault_video_${file.path.hashCode}',
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  void _openAudio(File file) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AudioPlayerBottomSheet(
        filePath: file.path,
        fileName: file.path.split('/').last.split('\\').last,
      ),
    );
  }

  void _openDocument(File file) {
    final path = file.path;
    final lowerName = path.toLowerCase();
    final fileName = path.split('/').last.split('\\').last;

    if (lowerName.endsWith('.txt') ||
        lowerName.endsWith('.md') ||
        lowerName.endsWith('.json') ||
        lowerName.endsWith('.dart') ||
        lowerName.endsWith('.js') ||
        lowerName.endsWith('.py') ||
        lowerName.endsWith('.csv') ||
        lowerName.endsWith('.log') ||
        lowerName.endsWith('.xml') ||
        lowerName.endsWith('.yaml')) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FullScreenTextViewer(
            filePath: path,
            sender: 'Local Device',
            timestamp: file.lastModifiedSync(),
            fileName: fileName,
            heroTag: 'vault_doc_${path.hashCode}',
          ),
        ),
      );
    } else {
      _openFileWithSystemDefaultDirectly(path, fileName);
    }
  }

  Future<void> _openFileWithSystemDefaultDirectly(String filePath, String fileName) async {
    try {
      final fileUri = Uri.file(filePath);
      if (await canLaunchUrl(fileUri)) {
        await launchUrl(fileUri);
      } else {
        // Fallback: Copy path to clipboard
        await Clipboard.setData(ClipboardData(text: filePath));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF1C1C1E),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              content: Text(
                'No app found to open file. Path copied to clipboard:\n$filePath',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error launching default viewer: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161618),
        elevation: 0,
        title: const Text(
          'Device Media Vault',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.1,
            fontFamily: 'Plus Jakarta Sans',
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF0A84FF),
          indicatorWeight: 3.0,
          labelColor: Colors.white,
          unselectedLabelColor: const Color(0xFF8E8E93),
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.0, fontFamily: 'Plus Jakarta Sans'),
          tabs: const [
            Tab(text: 'Images', icon: Icon(Icons.image, size: 20)),
            Tab(text: 'Videos', icon: Icon(Icons.videocam, size: 20)),
            Tab(text: 'Audio', icon: Icon(Icons.audiotrack, size: 20)),
            Tab(text: 'Docs', icon: Icon(Icons.insert_drive_file, size: 20)),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF0A84FF)))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildImagesGrid(),
                _buildVideosGrid(),
                _buildAudioList(),
                _buildDocsList(),
              ],
            ),
    );
  }

  Widget _buildImagesGrid() {
    if (_images.isEmpty) {
      return _buildEmptyState(Icons.image, 'No Images Found', 'Photos you download will be stored here.');
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _images.length,
      itemBuilder: (context, index) {
        final file = _images[index];
        return GestureDetector(
          onTap: () => _openImage(file),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(20), width: 1.0),
            ),
            clipBehavior: Clip.antiAlias,
            child: Hero(
              tag: 'vault_image_${file.path.hashCode}',
              child: Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (context, err, st) => const Center(
                  child: Icon(Icons.broken_image, color: Colors.grey),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideosGrid() {
    if (_videos.isEmpty) {
      return _buildEmptyState(Icons.videocam, 'No Videos Found', 'Shared video clips will appear in this tab.');
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.3,
      ),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final file = _videos[index];
        final fileName = file.path.split('/').last.split('\\').last;

        return GestureDetector(
          onTap: () => _openVideo(file),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withAlpha(20), width: 1.0),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF2C2C2E), Color(0xFF1C1C1E)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.video_library,
                        color: Colors.white24,
                        size: 40,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black87, Colors.transparent],
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _getFileSizeString(file),
                          style: const TextStyle(color: Colors.white70, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      color: Color(0xFF0A84FF),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAudioList() {
    if (_audio.isEmpty) {
      return _buildEmptyState(Icons.audiotrack, 'No Audio Found', 'Audio logs or voice recordings will be saved here.');
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _audio.length,
      itemBuilder: (context, index) {
        final file = _audio[index];
        final fileName = file.path.split('/').last.split('\\').last;

        return Card(
          color: const Color(0xFF161618),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            onTap: () => _openAudio(file),
            leading: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF30D158).withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.music_note, color: Color(0xFF30D158)),
            ),
            title: Text(
              fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
            ),
            subtitle: Text(
              '${_getFileSizeString(file)} • Audio Track',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
            trailing: const Icon(Icons.play_circle_fill, color: Color(0xFF30D158), size: 28),
          ),
        );
      },
    );
  }

  Widget _buildDocsList() {
    if (_documents.isEmpty) {
      return _buildEmptyState(Icons.insert_drive_file, 'No Documents Found', 'Downloaded reports, PDFs, and text logs vault here.');
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _documents.length,
      itemBuilder: (context, index) {
        final file = _documents[index];
        final fileName = file.path.split('/').last.split('\\').last;
        final extension = fileName.contains('.') ? fileName.split('.').last.toUpperCase() : 'FILE';

        return Card(
          color: const Color(0xFF161618),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            onTap: () => _openDocument(file),
            leading: Hero(
              tag: 'vault_doc_${file.path.hashCode}',
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A84FF).withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF0A84FF).withAlpha(100), width: 1.0),
                ),
                child: Center(
                  child: Text(
                    extension,
                    style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
            title: Text(
              fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
            ),
            subtitle: Text(
              '${_getFileSizeString(file)} • Document',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
            trailing: const Icon(Icons.open_in_new, color: Color(0xFF8E8E93), size: 18),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(IconData icon, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.white24),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// PREMIUM GLASSMORPHIC BOTTOM SHEET AUDIO PLAYER WIDGET
class _AudioPlayerBottomSheet extends StatefulWidget {
  final String filePath;
  final String fileName;

  const _AudioPlayerBottomSheet({
    required this.filePath,
    required this.fileName,
  });

  @override
  State<_AudioPlayerBottomSheet> createState() => _AudioPlayerBottomSheetState();
}

class _AudioPlayerBottomSheetState extends State<_AudioPlayerBottomSheet> with SingleTickerProviderStateMixin {
  late VideoPlayerController _controller;
  late AnimationController _rotationController;
  bool _isInitialized = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      duration: const Duration(seconds: 12),
      vsync: this,
    );

    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        if (mounted) {
          setState(() {
            _duration = _controller.value.duration;
            _isInitialized = true;
          });
          _controller.addListener(_updatePosition);
        }
      });
  }

  @override
  void dispose() {
    _controller.removeListener(_updatePosition);
    _controller.dispose();
    _rotationController.dispose();
    super.dispose();
  }

  void _updatePosition() {
    if (mounted) {
      setState(() {
        _position = _controller.value.position;
        final playing = _controller.value.isPlaying;
        if (playing != _isPlaying) {
          _isPlaying = playing;
          if (_isPlaying) {
            _rotationController.repeat();
          } else {
            _rotationController.stop();
          }
        }
      });
    }
  }

  void _togglePlay() {
    HapticFeedback.lightImpact();
    if (_isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF161618),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(color: Colors.black54, blurRadius: 20, spreadRadius: 5),
        ],
      ),
      padding: const EdgeInsets.only(top: 12, left: 24, right: 24, bottom: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: const Color(0xFF3A3A3C),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          const SizedBox(height: 28),

          // Beautiful Rotating Vinyl Visualizer Disc
          Center(
            child: RotationTransition(
              turns: _rotationController,
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0F0F10),
                  border: Border.all(color: Colors.white.withAlpha(20), width: 4.0),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 15, spreadRadius: 3),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: const BoxDecoration(
                      color: Color(0xFF30D158),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.music_note,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Title & Details
          Text(
            widget.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Plus Jakarta Sans'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          const Text(
            'Local Audio Player',
            style: TextStyle(color: Colors.grey, fontSize: 11),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Slider Progress Row
          if (_isInitialized) ...[
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF30D158),
                inactiveTrackColor: const Color(0xFF2C2C2E),
                thumbColor: Colors.white,
                trackHeight: 3.0,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: _position.inMilliseconds.toDouble(),
                min: 0.0,
                max: _duration.inMilliseconds.toDouble(),
                onChanged: (val) {
                  _controller.seekTo(Duration(milliseconds: val.toInt()));
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_formatDuration(_position), style: const TextStyle(color: Colors.grey, fontSize: 10)),
                  Text(_formatDuration(_duration), style: const TextStyle(color: Colors.grey, fontSize: 10)),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2.0, valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF30D158))),
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 16),

          // Playback Control Button
          GestureDetector(
            onTap: _isInitialized ? _togglePlay : null,
            child: Container(
              width: 60,
              height: 60,
              decoration: const BoxDecoration(
                color: Color(0xFF30D158),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
