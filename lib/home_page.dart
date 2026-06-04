import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'auth_page.dart';
import 'ably_service.dart';
import 'friend_request_page.dart';
import 'chat_page.dart';
import 'widgets/youtube_shorts_feed.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _currentIndex = 0;
  int _previousIndex = 0;
  Map<String, dynamic>? _userData;
  bool _isSidebarOpen = false;
  int _requestsSegment = 0; // 0=Received, 1=Sent, 2=Activity
  Map<String, Map<String, dynamic>> _usersCache = {};
  StreamSubscription<QuerySnapshot>? _usersSubscription;

  final Map<String, bool> _typingStates = {};
  final Map<String, StreamSubscription> _typingSubscriptions = {};



  StreamSubscription<QuerySnapshot>? _receivedRequestsSubscription;
  StreamSubscription<QuerySnapshot>? _sentRequestsSubscription;
  StreamSubscription<QuerySnapshot>? _activityFeedSubscription;



  // Separate search bars for all 5 tabs (controllers and query states)
  late final List<TextEditingController> _searchControllers;
  final List<String> _searchQueries = List.generate(5, (_) => '');
  late final PageController _pageController;
  final TextEditingController _momentsEmailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateOnlineStatus(true);
    _fetchUserData();
    _pageController = PageController(initialPage: _currentIndex);
    _searchControllers = List.generate(5, (_) => TextEditingController());
    for (int i = 0; i < 5; i++) {
      _searchControllers[i].addListener(() {
        setState(() {
          _searchQueries[i] = _searchControllers[i].text.trim().toLowerCase();
        });
      });
    }

    // Listen to push notification clicks (mobile only)
    if (!kIsWeb) {
      _setupPushNotificationClickHandlers();
    }

    // Cache userdetails in real-time to load profile pictures instantly everywhere
    _usersSubscription = FirebaseFirestore.instance
        .collection('userdetails')
        .snapshots()
        .listen((snapshot) {
      final cache = <String, Map<String, dynamic>>{};
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final username = data['username'] as String? ?? '';
        if (username.isNotEmpty) {
          cache[username.toLowerCase()] = data;
        }
      }
      if (mounted) {
        setState(() {
          _usersCache = cache;
        });
      }
    });
  }

  void _setupPushNotificationClickHandlers() {
    try {
      // Terminated state click handler
      FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
        if (message != null) {
          _handleNotificationTap(message.data);
        }
      }).catchError((_) {});

      // Background state click handler
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        _handleNotificationTap(message.data);
      });
    } catch (_) {}
  }

  void _handleNotificationTap(Map<String, dynamic> data) {
    final String? type = data['type'];
    if (type == null) return;

    if (type == 'sent') {
      setState(() {
        _currentIndex = 4;
        _requestsSegment = 0;
      });
      _pageController.jumpToPage(4);
    } else if (type == 'accepted' || type == 'declined') {
      setState(() {
        _currentIndex = 4;
        _requestsSegment = (type == 'accepted') ? 2 : 1;
      });
      _pageController.jumpToPage(4);
    }
  }



  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateOnlineStatus(false);
    _usersSubscription?.cancel();
    _receivedRequestsSubscription?.cancel();
    _sentRequestsSubscription?.cancel();
    _activityFeedSubscription?.cancel();
    for (var sub in _typingSubscriptions.values) {
      sub.cancel();
    }
    _typingSubscriptions.clear();
    _pageController.dispose();
    for (var controller in _searchControllers) {
      controller.dispose();
    }
    _momentsEmailController.dispose();
    AblyService.instance.dispose();
    super.dispose();
  }

  Future<void> _fetchUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('userdetails')
          .where('email', isEqualTo: user.email)
          .limit(1)
          .get();
      if (snapshot.docs.isNotEmpty) {
        setState(() {
          _userData = snapshot.docs.first.data();
        });
        // Initialize Ably with the user's username as clientId
        final username = _userData?['username'] as String? ?? '';
        if (username.isNotEmpty) {
          await AblyService.instance.init(username);
        }
      } else {
        // Safe protection: if the Firestore document is missing,
        // this is a dangling/incomplete auth record. Delete it and sign out.
        await FirebaseAuth.instance.currentUser?.delete();
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (c) => const AuthPage()));
      }
    } catch (_) {}
  }

  void _subscribeToTyping(String otherUser) {
    final lowerUser = otherUser.toLowerCase();
    if (_typingSubscriptions.containsKey(lowerUser)) return;

    final currentUsername = _userData?['username'] as String? ?? '';
    if (currentUsername.isEmpty) return;

    try {
      final channelName = AblyService.instance.getChatChannelName(currentUsername, otherUser);
      final channel = AblyService.instance.getChannel(channelName);
      final sub = channel.subscribe(name: 'typing').listen((message) {
        final data = message.data;
        if (data is Map) {
          final typing = data['typing'] as bool? ?? false;
          final sender = data['sender'] as String? ?? '';
          if (sender.toLowerCase() == lowerUser) {
            if (mounted) {
              setState(() {
                _typingStates[lowerUser] = typing;
              });
            }
          }
        }
      });
      _typingSubscriptions[lowerUser] = sub;
    } catch (_) {}
  }

  Future<void> _updateOnlineStatus(bool isOnline) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('userdetails')
          .where('email', isEqualTo: user.email)
          .limit(1)
          .get();
      if (snapshot.docs.isNotEmpty) {
        await snapshot.docs.first.reference.update({'isOnline': isOnline});
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updateOnlineStatus(true);
    } else {
      _updateOnlineStatus(false);
    }
  }



  // Fixed Apple Blue theme color for all users — comfortable for eyes
  static const Color _appleBlue = Color(0xFF0A84FF);

  Color get _themeColor => _appleBlue;

  Color _parseColor(String colorString) {
    if (colorString.startsWith('#')) {
      final hex = colorString.substring(1);
      if (hex.length == 6) {
        return Color(0xFF000000 | int.parse(hex, radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }
    return _appleBlue; // Default fallback
  }

  String _userInitial() {
    final username = _userData?['username'] as String? ?? '';
    return username.isNotEmpty ? username[0].toUpperCase() : 'U';
  }

  @override
  Widget build(BuildContext context) {
    final Color accentColor = _themeColor;
    final String currentUsername = _userData?['username'] ?? 'user';
    final String profilePictureUrl = _userData?['profilePictureUrl'] ?? '';

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      // Use a custom top bar instead of standard AppBar for precise layout control
      appBar: _currentIndex == 2 ? null : PreferredSize(
        preferredSize: const Size.fromHeight(76),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(left: 20, right: 20, top: 10, bottom: 0), // perfectly centered top gap
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ═══════════════════════════════════════════════════
                // ELEMENT 1: Hamburger Menu Button (circular dark bg)
                // ═══════════════════════════════════════════════════
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _isSidebarOpen = !_isSidebarOpen;
                    });
                  },
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF48484A), width: 1.0),
                    ),
                    child: const Icon(Icons.menu, color: Colors.white, size: 21),
                  ),
                ),

                const SizedBox(width: 4),

                // ═══════════════════════════════════════════════════
                // ELEMENT 2: Premium App Icon beside Hamburger
                // ═══════════════════════════════════════════════════
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset(
                    'assets/icon.png',
                    height: 66,
                    width: 66,
                    fit: BoxFit.cover,
                  ),
                ),

                const Spacer(),

                // ═══════════════════════════════════════════════════
                // ELEMENT 3: Profile Capsule / Pill (@username chip) - Non-interactive
                // ═══════════════════════════════════════════════════
                Container(
                  height: 46,
                  constraints: const BoxConstraints(maxWidth: 150),
                  padding: const EdgeInsets.only(left: 6, right: 15),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(23),
                    border: Border.all(color: const Color(0xFF48484A), width: 1.0),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Small avatar circle inside the pill
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: _parseColor(_userData?['avatarColor'] ?? ''),
                        backgroundImage: profilePictureUrl.isNotEmpty
                            ? NetworkImage(profilePictureUrl)
                            : null,
                        child: profilePictureUrl.isEmpty
                            ? Text(
                                _userInitial(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 8),
                      // @username text
                      Flexible(
                        child: Text(
                          '@$currentUsername',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
      body: Column(
        children: [
          // ═══════════════════════════════════════════════════
          // ELEMENT 4: Search Bar ("Search friends...") with Premium sliding/fading AnimatedSwitcher
          // ═══════════════════════════════════════════════════
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (Widget child, Animation<double> animation) {
              final isEntering = child.key == ValueKey<int>(_currentIndex);
              final double xOffset = _currentIndex >= _previousIndex ? 0.35 : -0.35;

              final Tween<Offset> slideTween = isEntering
                  ? Tween<Offset>(begin: Offset(xOffset, 0.0), end: Offset.zero)
                  : Tween<Offset>(begin: Offset(-xOffset, 0.0), end: Offset.zero);

              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: slideTween.animate(CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  )),
                  child: child,
                ),
              );
            },
            child: _currentIndex == 4
                ? _buildRequestsSegmentBar(accentColor)
                : _currentIndex == 2
                    ? const SizedBox.shrink() // Immersive: no search bar on Timepass
                    : _buildSearchBar(accentColor),
          ),
          if (_currentIndex != 2) // Immersive: no divider on Timepass
            const Divider(
              color: Color(0xFF6C6C70),
              thickness: 1.0,
              height: 1.0,
            ),
          Expanded(
            child: Stack(
              children: [
                _buildBodyContent(accentColor),
                // Fading background scrim overlay
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_isSidebarOpen,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _isSidebarOpen = false;
                        });
                      },
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 550),
                        opacity: _isSidebarOpen ? 1.0 : 0.0,
                        child: Container(
                          color: const Color(0x8C000000),
                        ),
                      ),
                    ),
                  ),
                ),
                // Custom sliding sidebar (bounded between search divider and bottom bar)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 550),
                  curve: Curves.easeOutQuart,
                  left: _isSidebarOpen ? 0 : -280,
                  top: 0,
                  bottom: 0,
                  width: 280,
                  child: _buildCustomSidebar(accentColor),
                ),
              ],
            ),
          ),
        ],
      ),
      // ═══════════════════════════════════════════════════
      // ELEMENT 5: Bottom Navigation Bar (3 tabs)
      // ═══════════════════════════════════════════════════
      bottomNavigationBar: _buildBottomNavigationBar(accentColor),
    );
  }

  Widget _buildSearchBar(Color accentColor) {
    final List<String> hints = [
      'Search messages & chats...',
      'Search moments & stories...',
      'Search videos & reels...',
      'Search and add friends...',
      'Search requests...',
    ];

    final controller = _searchControllers[_currentIndex];
    final query = _searchQueries[_currentIndex];
    final hint = hints[_currentIndex];

    return Container(
      key: ValueKey<int>(_currentIndex),
      height: 50,
      margin: const EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 10), // premium centered vertical gap from AppBar
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: const Color(0xFF48484A), width: 1.0),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.search, color: Color(0xFF8E8E93), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: ValueKey<int>(_currentIndex), // Ensure clean rebuild when switching tabs
              controller: controller,
              textAlignVertical: TextAlignVertical.center,
              autofocus: false,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (query.isNotEmpty)
            GestureDetector(
              onTap: () => controller.clear(),
              child: const Icon(Icons.close, color: Color(0xFF8E8E93), size: 18),
            ),
        ],
      ),
    );
  }



  Widget _buildBodyContent(Color accentColor) {
    if (_userData == null) {
      return Center(child: CircularProgressIndicator(color: accentColor));
    }

    return PageView(
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      onPageChanged: (index) {
        setState(() {
          _previousIndex = _currentIndex;
          _currentIndex = index;
        });
      },
      children: [
        _buildChatsTab(accentColor),
        _buildMomentsTab(accentColor),
        _buildTimepassTab(accentColor),
        _buildFriendsTab(accentColor),
        _buildRequestsTab(accentColor),
      ],
    );
  }

  Widget _buildChatsTab(Color accentColor) {
    final String currentUsername = _userData?['username'] ?? '';
    if (currentUsername.isEmpty) {
      return Center(child: CircularProgressIndicator(color: accentColor));
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: currentUsername.toLowerCase())
          .snapshots(),
      builder: (context, chatsSnapshot) {
        // Build a map of channelName -> updatedAt timestamp
        final Map<String, Timestamp> chatTimestamps = {};
        if (chatsSnapshot.hasData) {
          for (var doc in chatsSnapshot.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final ts = data['updatedAt'] as Timestamp?;
            if (ts != null) {
              chatTimestamps[doc.id] = ts;
            }
          }
        }

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('relationships')
              .where('status', isEqualTo: 'friends')
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                child: Text(
                  'Error loading chats',
                  style: TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
                ),
              );
            }
            if (!snapshot.hasData) {
              return Center(child: CircularProgressIndicator(color: accentColor));
            }

            // Filter relationships locally where either from or to is currentUsername
            final relationshipDocs = snapshot.data!.docs.where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final from = (data['from'] as String? ?? '').toLowerCase();
              final to = (data['to'] as String? ?? '').toLowerCase();
              final lowerMe = currentUsername.toLowerCase();
              
              // Filter out chats hidden by the current user in the main list, UNLESS a search query is active!
              final hiddenBy = List<String>.from(data['hiddenBy'] ?? []);
              final queryText = _searchQueries[0].trim().toLowerCase();
              if (hiddenBy.contains(lowerMe) && queryText.isEmpty) {
                return false;
              }

              return from == lowerMe || to == lowerMe;
            }).toList();

            // Apply local search filtering if a search query is typed in the Chats tab
            final queryText = _searchQueries[0].trim().toLowerCase();
            final filteredRelationships = relationshipDocs.where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final from = data['from'] as String? ?? '';
              final to = data['to'] as String? ?? '';
              final otherUser = from.toLowerCase() == currentUsername.toLowerCase() ? to : from;
              return otherUser.toLowerCase().contains(queryText);
            }).toList();

            if (filteredRelationships.isEmpty) {
              return Center(
                child: Text(
                  queryText.isEmpty
                      ? 'No active chats yet. Go to Friends to start one!'
                      : 'No matching chats found',
                  style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
                ),
              );
            }

            // Dynamically sort relationships by the most recent chat timestamp, prioritizing Favourites first!
            // Falling back to relationship acceptance/updatedAt timestamp if no chat exists yet
            filteredRelationships.sort((a, b) {
              final dataA = a.data() as Map<String, dynamic>;
              final dataB = b.data() as Map<String, dynamic>;

              final favA = List<String>.from(dataA['favouritedBy'] ?? []).contains(currentUsername);
              final favB = List<String>.from(dataB['favouritedBy'] ?? []).contains(currentUsername);

              if (favA && !favB) return -1;
              if (!favA && favB) return 1;

              final fromA = dataA['from'] as String? ?? '';
              final toA = dataA['to'] as String? ?? '';
              final otherUserA = fromA.toLowerCase() == currentUsername.toLowerCase() ? toA : fromA;
              final channelA = AblyService.instance.getChatChannelName(currentUsername, otherUserA);

              final fromB = dataB['from'] as String? ?? '';
              final toB = dataB['to'] as String? ?? '';
              final otherUserB = fromB.toLowerCase() == currentUsername.toLowerCase() ? toB : fromB;
              final channelB = AblyService.instance.getChatChannelName(currentUsername, otherUserB);

              final tsA = chatTimestamps[channelA] ?? dataA['updatedAt'] as Timestamp? ?? Timestamp(0, 0);
              final tsB = chatTimestamps[channelB] ?? dataB['updatedAt'] as Timestamp? ?? Timestamp(0, 0);

              return tsB.compareTo(tsA); // Descending order (latest chat first!)
            });

            return ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: filteredRelationships.length,
              itemBuilder: (context, index) {
            final doc = filteredRelationships[index];
            final data = doc.data() as Map<String, dynamic>;
            final from = data['from'] as String? ?? '';
            final to = data['to'] as String? ?? '';
            final String otherUser = from.toLowerCase() == currentUsername.toLowerCase() ? to : from;

            // Look up from the users Cache to load profile pictures instantly
            final userDetail = _usersCache[otherUser.toLowerCase()] ?? {};
            final String picUrl = userDetail['profilePictureUrl'] ?? '';
            final String avatarHex = userDetail['avatarColor'] ?? '';

            // Subscribe to typing indicators for this user dynamically
            _subscribeToTyping(otherUser);

            // Retrieve last message and last message timestamp if available
            final channelName = AblyService.instance.getChatChannelName(currentUsername, otherUser);

            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(channelName)
                  .collection('messages')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, messagesSnapshot) {
                String lastMessage = '';
                Timestamp? lastTimestamp;

                if (messagesSnapshot.hasData && messagesSnapshot.data!.docs.isNotEmpty) {
                  final visibleDocs = messagesSnapshot.data!.docs.where((doc) {
                    final msgData = doc.data() as Map<String, dynamic>;
                    final deletedFor = List<String>.from(msgData['deletedFor'] ?? []);
                    return !deletedFor.contains(currentUsername);
                  }).toList();

                  if (visibleDocs.isNotEmpty) {
                    final latestDoc = visibleDocs.first;
                    final latestData = latestDoc.data() as Map<String, dynamic>;
                    
                    lastMessage = latestData['text'] as String? ?? '';
                    if (lastMessage.startsWith('anim_emoji_noto:')) {
                      final emojiCodepoint = lastMessage.substring('anim_emoji_noto:'.length);
                      try {
                        final cpParts = emojiCodepoint.split('_');
                        lastMessage = cpParts.map((part) => String.fromCharCode(int.parse(part, radix: 16))).join();
                      } catch (_) {
                        lastMessage = '🎬';
                      }
                    }
                    lastTimestamp = latestData['timestamp'] as Timestamp?;
                  }
                }

                // If no visible messages in chat history (cleared or empty), show 'Start conversation' and hide time!
                if (lastMessage.isEmpty) {
                  lastMessage = 'Start conversation';
                  lastTimestamp = null;
                }

                String getVerticalTimestamp(Timestamp? ts) {
                  if (ts == null) return '';
                  final dt = ts.toDate().toLocal();
                  final now = DateTime.now();
                  final today = DateTime(now.year, now.month, now.day);
                  final yesterday = today.subtract(const Duration(days: 1));
                  final dateOfMessage = DateTime(dt.year, dt.month, dt.day);

                  if (dateOfMessage == today) {
                    return DateFormat.jm().format(dt); // e.g. "3:42 PM"
                  } else if (dateOfMessage == yesterday) {
                    return 'Yesterday';
                  } else {
                    return DateFormat('MMM d').format(dt); // e.g. "May 25"
                  }
                }

                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatPage(
                          currentUsername: currentUsername,
                          targetUsername: otherUser,
                          avatarColor: _parseColor(avatarHex),
                          profilePictureUrl: picUrl,
                          accentColor: accentColor,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 1),
                    padding: const EdgeInsets.only(left: 16, right: 8, top: 12, bottom: 12),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1C1C1E),
                      border: Border(
                        bottom: BorderSide(color: Color(0xFF2C2C2E), width: 1.0),
                      ),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: _parseColor(avatarHex),
                          backgroundImage: picUrl.isNotEmpty ? NetworkImage(picUrl) : null,
                          child: picUrl.isEmpty
                              ? Text(
                                  otherUser.isNotEmpty ? otherUser[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.white, fontSize: 16),
                                )
                              : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    otherUser,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.normal,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (List<String>.from(data['favouritedBy'] ?? []).contains(currentUsername))
                                    const Padding(
                                      padding: EdgeInsets.only(right: 6),
                                      child: Icon(Icons.favorite, color: Color(0xFFFF2D55), size: 13),
                                    ),
                                  if (List<String>.from(data['mutedBy'] ?? []).contains(currentUsername))
                                    const Padding(
                                      padding: EdgeInsets.only(right: 6),
                                      child: Icon(Icons.notifications_off, color: Color(0xFF8E8E93), size: 13),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              () {
                                final isTyping = _typingStates[otherUser.toLowerCase()] == true;
                                final draftText = ChatPage.drafts[otherUser.toLowerCase()];

                                if (isTyping) {
                                  return Text(
                                    'typing...',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: accentColor,
                                      fontSize: 14,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  );
                                } else if (draftText != null && draftText.isNotEmpty) {
                                  return Text.rich(
                                    TextSpan(
                                      children: [
                                        const TextSpan(
                                          text: 'Draft: ',
                                          style: TextStyle(
                                            color: Colors.redAccent,
                                            fontWeight: FontWeight.normal,
                                          ),
                                        ),
                                        TextSpan(
                                          text: draftText,
                                          style: const TextStyle(
                                            color: Color(0xFF8E8E93),
                                          ),
                                        ),
                                      ],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14),
                                  );
                                } else {
                                  return Text(
                                    lastMessage,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFF8E8E93),
                                      fontSize: 14,
                                    ),
                                  );
                                }
                              }(),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (lastTimestamp != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: RotatedBox(
                              quarterTurns: 3, // Rotates 90 degrees counter-clockwise
                              child: Text(
                                getVerticalTimestamp(lastTimestamp),
                                style: const TextStyle(
                                  color: Color(0xFF8E8E93),
                                  fontSize: 11,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  },
);
}

  Widget _buildMomentsTab(Color accentColor) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    accentColor.withValues(alpha: 0.2),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -50,
            right: -50,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFFFF2D55).withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double screenHeight = constraints.maxHeight;
                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: screenHeight - 40),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: accentColor.withValues(alpha: 0.25)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.auto_awesome, color: accentColor, size: 14),
                              const SizedBox(width: 6),
                              Text(
                                'NEW FEATURE',
                                style: TextStyle(
                                  color: accentColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Moments',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Capture and share temporary snippets of your day with close friends. Beautiful, organic, and private.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 48),
                        SizedBox(
                          height: 200,
                          width: double.infinity,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Transform.translate(
                                offset: const Offset(-50, 10),
                                child: Transform.rotate(
                                  angle: -0.15,
                                  child: _buildStoryCardPlaceholder(
                                    avatarColor: const Color(0xFFFF2D55),
                                    creatorName: 'Sarah',
                                    caption: 'Chasing sunsets... 🌅',
                                    gradientColors: [const Color(0xFFFF9500), const Color(0xFFFF2D55)],
                                  ),
                                ),
                              ),
                              Transform.translate(
                                offset: const Offset(50, 15),
                                child: Transform.rotate(
                                  angle: 0.12,
                                  child: _buildStoryCardPlaceholder(
                                    avatarColor: const Color(0xFF34C759),
                                    creatorName: 'Alex',
                                    caption: 'Gaming session! 🎮🔥',
                                    gradientColors: [const Color(0xFF007AFF), const Color(0xFF34C759)],
                                  ),
                                ),
                              ),
                              Transform.translate(
                                offset: const Offset(0, 0),
                                child: Transform.scale(
                                  scale: 1.05,
                                  child: _buildStoryCardPlaceholder(
                                    avatarColor: accentColor,
                                    creatorName: 'You',
                                    caption: 'Creating something epic 🚀',
                                    gradientColors: [accentColor, accentColor.withValues(alpha: 0.4)],
                                    isInteractive: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 56),
                        const Text(
                          'BE THE FIRST TO KNOW',
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          constraints: const BoxConstraints(maxWidth: 420),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1E),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black38,
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              const SizedBox(width: 20),
                              const Icon(Icons.mail_outline_rounded, color: Colors.white30, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _momentsEmailController,
                                  style: const TextStyle(color: Colors.white, fontSize: 14),
                                  decoration: const InputDecoration(
                                    hintText: 'Enter your email address...',
                                    hintStyle: TextStyle(color: Colors.white30, fontSize: 14),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  final email = _momentsEmailController.text.trim();
                                  if (email.isEmpty || !email.contains('@')) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Please enter a valid email address!'),
                                        backgroundColor: Color(0xFFFF3B30),
                                      ),
                                    );
                                    return;
                                  }
                                  _momentsEmailController.clear();
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      backgroundColor: const Color(0xFF1C1C1E),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                      title: const Row(
                                        children: [
                                          Icon(Icons.stars, color: Colors.amber, size: 24),
                                          SizedBox(width: 10),
                                          Text('Early Access Granted', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                      content: const Text(
                                        '✨ Welcome to the circle!\n\nYou have been added to the VIP list. You will be the first to know when Moments goes live.',
                                        style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: Text('Awesome', style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                                child: Container(
                                  margin: const EdgeInsets.all(4),
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(colors: [accentColor, accentColor.withValues(alpha: 0.7)]),
                                    borderRadius: BorderRadius.circular(26),
                                  ),
                                  child: const Text(
                                    'Notify Me',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoryCardPlaceholder({
    required Color avatarColor,
    required String creatorName,
    required String caption,
    required List<Color> gradientColors,
    bool isInteractive = false,
  }) {
    return Container(
      width: 120,
      height: 180,
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D23),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1.0),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: gradientColors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Opacity(
                  opacity: 0.15,
                  child: Center(
                    child: Icon(
                      isInteractive ? Icons.camera_alt_rounded : Icons.photo_size_select_actual_rounded,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 10,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: avatarColor,
                child: Text(
                  creatorName[0].toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            Positioned(
              bottom: 12,
              left: 10,
              right: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    creatorName,
                    style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    caption,
                    style: const TextStyle(color: Colors.white54, fontSize: 8),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimepassTab(Color accentColor) {
    final String currentUsername = _userData?['username'] ?? 'user';
    final String query = _searchQueries[2];
    return YoutubeShortsFeed(
      currentUsername: currentUsername,
      accentColor: accentColor,
      isTabActive: _currentIndex == 2,
      searchQuery: query,
    );
  }

  Widget _buildFriendsTab(Color accentColor) {
    final queryText = _searchQueries[3].trim().toLowerCase();

    if (queryText.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Search for users by typing their username above',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
          ),
        ),
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('userdetails').snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'Error loading users',
              style: TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
            ),
          );
        }
        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator(color: accentColor));
        }

        final currentEmail = FirebaseAuth.instance.currentUser?.email;

        // Filter and map other users from Firestore
        final users = snapshot.data!.docs
            .map((doc) => doc.data() as Map<String, dynamic>)
            .where((data) {
          final email = data['email'] as String? ?? '';
          final username = (data['username'] as String? ?? '').toLowerCase();

          // Exclude the current logged-in user
          if (email.toLowerCase() == currentEmail?.toLowerCase()) {
            return false;
          }

          return username.contains(queryText);
        }).toList();

        if (users.isEmpty) {
          return const Center(
            child: Text(
              'No matching users found',
              style: TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
            ),
          );
        }

        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: users.length,
          itemBuilder: (context, index) {
            final userMap = users[index];
            final String uName = userMap['username'] ?? 'user';
            final String picUrl = userMap['profilePictureUrl'] ?? '';
            final String avatarHex = userMap['avatarColor'] ?? '';

            return GestureDetector(
              onTap: () {
                final currentUsername = _userData?['username'] ?? '';
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FriendRequestPage(
                      currentUsername: currentUsername,
                      targetUsername: uName,
                      avatarColor: _parseColor(avatarHex),
                      profilePictureUrl: picUrl,
                      accentColor: accentColor,
                    ),
                  ),
                );
              },
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: _parseColor(avatarHex),
                      backgroundImage: picUrl.isNotEmpty ? NetworkImage(picUrl) : null,
                      child: picUrl.isEmpty
                          ? Text(
                              uName.isNotEmpty ? uName[0].toUpperCase() : '?',
                              style: const TextStyle(color: Colors.white, fontSize: 16),
                            )
                          : null,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        '@$uName',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                    ),
                    StreamBuilder<DocumentSnapshot>(
                      stream: AblyService.instance.streamRelationship(
                        _userData?['username'] ?? '',
                        uName,
                      ),
                      builder: (context, relSnapshot) {
                        IconData iconData = Icons.person_add;
                        Color iconColor = Colors.grey;

                        if (relSnapshot.hasData && relSnapshot.data!.exists) {
                          final data = relSnapshot.data!.data() as Map<String, dynamic>?;
                          final status = data?['status'] as String? ?? 'none';
                          
                          if (status == 'pending') {
                            iconData = Icons.access_time; // Pending icon
                            iconColor = Colors.red;
                          } else if (status == 'friends') {
                            iconData = Icons.check_circle; // Already friends icon
                            iconColor = Colors.green;
                          }
                        }

                        return Icon(iconData, color: iconColor, size: 24);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRequestsSegmentBar(Color accentColor) {
    final List<String> segments = ['Received', 'Sent', 'Activity'];

    return Container(
      key: ValueKey<int>(_currentIndex),
      height: 50,
      margin: const EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 10),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: const Color(0xFF48484A), width: 1.0),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double segmentWidth = constraints.maxWidth / 3;
          return Stack(
            children: [
              // Animated sliding pill indicator
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOutCubic,
                left: segmentWidth * _requestsSegment,
                top: 0,
                bottom: 0,
                width: segmentWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF48484A),
                    borderRadius: BorderRadius.circular(21),
                  ),
                ),
              ),
              // Segment labels
              Row(
                children: List.generate(segments.length, (index) {
                  final isSelected = _requestsSegment == index;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _requestsSegment = index;
                        });
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          style: TextStyle(
                            color: isSelected ? Colors.white : const Color(0xFF8E8E93),
                            fontSize: 15,
                            fontWeight: FontWeight.normal,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(segments[index]),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _handleAccept(String requestId, String targetUser) async {
    final currentUsername = _userData?['username'] ?? '';
    if (currentUsername.isEmpty) return;

    try {
      await AblyService.instance.acceptFriendRequest(
        requestId: requestId,
        from: targetUser,
        to: currentUsername,
        acceptedBy: currentUsername,
      );

      // Publish Ably event for real-time notification
      if (AblyService.instance.isInitialized) {
        final channel = AblyService.instance.getRequestChannel(
          currentUsername,
          targetUser,
        );
        await AblyService.instance.publishRequestEvent(
          channel: channel,
          type: 'accepted',
          from: currentUsername,
          to: targetUser,
        );
      }
    } catch (_) {}
  }

  Future<void> _handleDecline(String requestId, String targetUser) async {
    final currentUsername = _userData?['username'] ?? '';
    if (currentUsername.isEmpty) return;

    try {
      await AblyService.instance.declineFriendRequest(
        requestId: requestId,
        declinedBy: currentUsername,
        otherUser: targetUser,
      );

      // Publish Ably event for real-time notification
      if (AblyService.instance.isInitialized) {
        final channel = AblyService.instance.getRequestChannel(
          currentUsername,
          targetUser,
        );
        await AblyService.instance.publishRequestEvent(
          channel: channel,
          type: 'declined',
          from: currentUsername,
          to: targetUser,
        );
      }
    } catch (_) {}
  }

  Widget _buildStatusBadge(String status) {
    Color bgColor;
    Color textColor;
    String label;

    if (status == 'accepted' || status == 'friends') {
      bgColor = const Color(0xFF14301B);
      textColor = const Color(0xFF30D158);
      label = 'ACCEPTED';
    } else if (status == 'declined' || status == 'rejected') {
      bgColor = const Color(0xFF411C1E);
      textColor = const Color(0xFFFB3B30);
      label = 'REJECTED';
    } else if (status == 'cancelled') {
      bgColor = const Color(0xFF2C2C2E);
      textColor = const Color(0xFF8E8E93);
      label = 'CANCELLED';
    } else {
      bgColor = const Color(0xFF0C2440);
      textColor = const Color(0xFF0A84FF);
      label = 'PENDING';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildRequestMessageBubble({
    required String label,
    required String message,
    required Color labelColor,
    required Color boxColor,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: boxColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: labelColor,
              fontSize: 12,
              fontWeight: FontWeight.normal,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            message,
            style: const TextStyle(
              color: Color(0xFFE5E5EA),
              fontSize: 12,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestsTab(Color accentColor) {
    final currentUsername = _userData?['username'] ?? '';
    if (currentUsername.isEmpty) return const SizedBox.shrink();

    if (_requestsSegment == 0 || _requestsSegment == 1) {
      // ═══════════════════════════════════════════════════
      // REALTIME DATABASE FOR RECEIVED AND SENT REQUESTS
      // ═══════════════════════════════════════════════════
      final stream = _requestsSegment == 0
          ? AblyService.instance.getReceivedRequestsStream(currentUsername)
          : AblyService.instance.getSentRequestsStream(currentUsername);

      return StreamBuilder<QuerySnapshot>(
        key: ValueKey<int>(_requestsSegment), // Ensure clean rebuild when switching segment
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading requests: ${snapshot.error}',
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
              ),
            );
          }
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator(color: accentColor));
          }

          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            final List<String> segmentLabels = ['Received', 'Sent', 'Activity'];
            return Center(
              child: Text(
                'No ${segmentLabels[_requestsSegment].toLowerCase()} yet',
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
              ),
            );
          }

          // Convert map to list and sort by timestamp
          final items = docs.map((doc) {
            final val = doc.data() as Map<String, dynamic>;
            final timestamp = val['createdAt'] != null ? (val['createdAt'] as Timestamp).millisecondsSinceEpoch : 0;
            return {
              'id': doc.id,
              'user': _requestsSegment == 0 ? (val['from'] as String? ?? '') : (val['to'] as String? ?? ''),
              'message': val['message'] as String? ?? '',
              'timestamp': timestamp,
              'status': val['status'] as String? ?? 'pending',
              'responseMessage': val['responseMessage'] as String? ?? '',
            };
          }).toList();

          // Sort descending by timestamp
          items.sort((a, b) => (b['timestamp'] as num).compareTo(a['timestamp'] as num));

          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final targetUser = item['user'] as String;
              final messagePreview = item['message'] as String;
              final status = item['status'] as String;
              final responseMessage = item['responseMessage'] as String;
              final requestId = item['id'] as String;
              final timestampVal = item['timestamp'];

              // Instant cache lookup for zero-lag profile pictures and avatar colors!
              final userData = _usersCache[targetUser.toLowerCase()];
              final String picUrl = userData?['profilePictureUrl'] ?? '';
              final String avatarHex = userData?['avatarColor'] ?? '';

              if (_requestsSegment == 0) {
                // ═══════════════════════════════════════════════════
                // RECEIVED TAB CARD LAYOUT (Accept/Reject Buttons)
                // ═══════════════════════════════════════════════════
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: _parseColor(avatarHex),
                            backgroundImage: picUrl.isNotEmpty ? NetworkImage(picUrl) : null,
                            child: picUrl.isEmpty
                                ? Text(
                                    targetUser.isNotEmpty ? targetUser[0].toUpperCase() : '?',
                                    style: const TextStyle(color: Colors.white, fontSize: 13),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            targetUser,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                          const Spacer(),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (status != 'pending')
                                _buildStatusBadge(status),
                              const SizedBox(height: 4),
                              Text(
                                formatLocalTimestamp(timestampVal),
                                style: const TextStyle(
                                  color: Color(0xFF8E8E93),
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (status == 'pending') ...[
                        Text(
                          messagePreview,
                          style: const TextStyle(
                            color: Color(0xFFC7C7CC),
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            TextButton(
                              onPressed: () => _handleAccept(requestId, targetUser),
                              child: const Text(
                                'Accept',
                                style: TextStyle(
                                  color: Color(0xFF0A84FF),
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => _handleDecline(requestId, targetUser),
                              child: const Text(
                                'Reject',
                                style: TextStyle(
                                  color: Color(0xFFFF453A),
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        _buildRequestMessageBubble(
                          label: 'You:',
                          message: messagePreview,
                          labelColor: const Color(0xFF0A84FF),
                          boxColor: const Color(0xFF1C2C3E),
                        ),
                        if (responseMessage.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          _buildRequestMessageBubble(
                            label: '$targetUser:',
                            message: responseMessage,
                            labelColor: const Color(0xFFFF453A),
                            boxColor: const Color(0xFF2E1E20),
                          ),
                        ],
                      ],
                    ],
                  ),
                );
              } else {
                // ═══════════════════════════════════════════════════
                // SENT TAB CARD LAYOUT (Double Bubbles with Status)
                // ═══════════════════════════════════════════════════
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: _parseColor(avatarHex),
                            backgroundImage: picUrl.isNotEmpty ? NetworkImage(picUrl) : null,
                            child: picUrl.isEmpty
                                ? Text(
                                    targetUser.isNotEmpty ? targetUser[0].toUpperCase() : '?',
                                    style: const TextStyle(color: Colors.white, fontSize: 13),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            targetUser,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                          const Spacer(),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _buildStatusBadge(status),
                              const SizedBox(height: 4),
                              Text(
                                formatLocalTimestamp(timestampVal),
                                style: const TextStyle(
                                  color: Color(0xFF8E8E93),
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildRequestMessageBubble(
                        label: 'You:',
                        message: messagePreview,
                        labelColor: const Color(0xFF0A84FF),
                        boxColor: const Color(0xFF1C2C3E),
                      ),
                      if (status != 'pending' && responseMessage.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _buildRequestMessageBubble(
                          label: '$targetUser:',
                          message: responseMessage,
                          labelColor: const Color(0xFFFF453A),
                          boxColor: const Color(0xFF2E1E20),
                        ),
                      ] else if (status == 'declined') ...[
                        const SizedBox(height: 8),
                        _buildRequestMessageBubble(
                          label: '$targetUser:',
                          message: "Request couldn't be accepted right now—maybe another time.",
                          labelColor: const Color(0xFFFF453A),
                          boxColor: const Color(0xFF2E1E20),
                        ),
                      ],
                    ],
                  ),
                );
              }
            },
          );
        },
      );
    } else {
      // ═══════════════════════════════════════════════════
      // FIRESTORE STREAM FOR ACTIVITY FEED
      // ═══════════════════════════════════════════════════
      final stream = AblyService.instance.getActivityFeed(currentUsername);

      return StreamBuilder<QuerySnapshot>(
        key: ValueKey<int>(_requestsSegment),
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading activity feed: ${snapshot.error}',
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
              ),
            );
          }
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator(color: accentColor));
          }

          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text(
                'No activity feed yet',
                style: TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
              ),
            );
          }

          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              final type = data['type'] as String? ?? '';
              final otherUser = data['otherUser'] as String? ?? '';
              final message = data['message'] as String?;

              String title = '';
              String subtitle = '';
              Color typeColor = accentColor;
              String typeLabel = '';

              if (type == 'sent') {
                typeLabel = 'CONNECTION REQUEST';
                title = 'You sent a request to $otherUser';
              } else if (type == 'received') {
                typeLabel = 'CONNECTION REQUEST';
                title = '$otherUser wants to connect';
              } else if (type == 'accepted') {
                typeLabel = 'REQUEST ACCEPTED';
                typeColor = const Color(0xFF30D158);
                if (data['user'] == otherUser) {
                  title = '$otherUser accepted your request';
                } else {
                  title = 'You accepted $otherUser\'s request';
                }
                subtitle = message ?? '';
              } else if (type == 'declined') {
                typeLabel = 'REQUEST DECLINED';
                typeColor = const Color(0xFFFF453A);
                title = 'Request with $otherUser was declined';
              } else if (type == 'cancelled') {
                typeLabel = 'REQUEST CANCELLED';
                typeColor = const Color(0xFF8E8E93);
                if (data['user'] == otherUser) {
                  title = '$otherUser cancelled their request';
                } else {
                  title = 'You cancelled your request to $otherUser';
                }
              }

              return Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          typeLabel,
                          style: TextStyle(
                            color: typeColor,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          formatLocalTimestamp(data['timestamp']),
                          style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      );
    }
  }

  Widget _buildBottomNavigationBar(Color accentColor) {
    final double tabWidth = MediaQuery.of(context).size.width / 5;
    final List<Map<String, dynamic>> tabs = [
      {'label': 'Chats', 'activeIcon': Icons.chat_bubble, 'inactiveIcon': Icons.chat_bubble_outline},
      {'label': 'Moments', 'activeIcon': Icons.feed, 'inactiveIcon': Icons.feed_outlined},
      {'label': 'Timepass', 'activeIcon': Icons.play_circle, 'inactiveIcon': Icons.play_circle_outline},
      {'label': 'Add Friends', 'activeIcon': Icons.person_add_alt_1, 'inactiveIcon': Icons.person_add_alt_1_outlined},
      {'label': 'Requests', 'activeIcon': Icons.group_add, 'inactiveIcon': Icons.group_add_outlined},
    ];

    return Container(
      color: const Color(0xFF1C1C1E), // Stretches perfectly to the bottom of the device screen
      child: SafeArea(
        top: false, // only pad bottom
        child: Container(
          height: 70, // Increased height for superior breathing room
          decoration: const BoxDecoration(
            color: Color(0xFF1C1C1E),
            border: Border(
              top: BorderSide(color: Color(0xFF2C2C2E), width: 1.0), // flat separating top line
            ),
          ),
          child: Stack(
            children: [
              // LinkedIn-style animated sliding top active bar indicator with professional Curve
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOutCubic, // fluid, professional glide
                left: tabWidth * _currentIndex + (tabWidth - 40) / 2,
                top: 0,
                child: Container(
                  width: 40,
                  height: 3,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
              // Tab Items row
              Row(
                children: List.generate(tabs.length, (index) {
                  final isSelected = _currentIndex == index;
                  final tab = tabs[index];
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _previousIndex = _currentIndex;
                          _currentIndex = index;
                        });
                        _pageController.jumpToPage(index);
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 6),
                          // Premium fluid fading Icon color transition (zero scale/bouncy effects)
                          TweenAnimationBuilder<Color?>(
                            duration: const Duration(milliseconds: 200),
                            tween: ColorTween(
                              begin: const Color(0xFF8E8E93),
                              end: isSelected ? accentColor : const Color(0xFF8E8E93),
                            ),
                            builder: (context, color, child) {
                              return Icon(
                                isSelected ? tab['activeIcon'] : tab['inactiveIcon'],
                                color: color,
                                size: 23,
                              );
                            },
                          ),
                          const SizedBox(height: 4),
                          // Smooth fading Text label color transition (zero scale/bouncy effects)
                          TweenAnimationBuilder<Color?>(
                            duration: const Duration(milliseconds: 200),
                            tween: ColorTween(
                              begin: const Color(0xFF8E8E93),
                              end: isSelected ? Colors.white : const Color(0xFF8E8E93),
                            ),
                            builder: (context, color, child) {
                              return FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  tab['label'],
                                  style: TextStyle(
                                    color: color,
                                    fontSize: 10,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  maxLines: 1,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 6,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _buildCustomSidebar(Color accentColor) {
    final currentUsername = _userData?['username'] as String? ?? '';
    final String profilePictureUrl = _userData?['profilePictureUrl'] ?? '';

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
        border: Border(
          right: BorderSide(color: Color(0xFF2C2C2E), width: 1.0),
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x7F000000),
            blurRadius: 15,
            spreadRadius: 2,
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF2C2C2E), width: 1.0)),
              ),
              child: Row(
                children: [
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: _parseColor(_userData?['avatarColor'] ?? ''),
                        backgroundImage: profilePictureUrl.isNotEmpty
                            ? NetworkImage(profilePictureUrl)
                            : null,
                        child: profilePictureUrl.isEmpty
                            ? Text(
                                _userInitial(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : null,
                      ),
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: const Color(0xFF30D158),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF111111), width: 1.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '@$currentUsername',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _userData?['email'] ?? '',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                physics: const BouncingScrollPhysics(),
                children: [
                  _buildSidebarCard(
                    icon: Icons.favorite,
                    iconColor: const Color(0xFFFF2D55),
                    title: 'Favourites',
                    child: currentUsername.isNotEmpty
                        ? StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('relationships')
                                .where('favouritedBy', arrayContains: currentUsername)
                                .snapshots(),
                            builder: (context, snap) {
                              if (!snap.hasData || snap.data!.docs.isEmpty) {
                                return const Text(
                                  'No favourites yet',
                                  style: TextStyle(color: Color(0xFF6C6C70), fontSize: 13),
                                );
                              }

                              final favDocs = snap.data!.docs.where((doc) {
                                final data = doc.data() as Map<String, dynamic>;
                                return data['status'] == 'friends';
                              }).toList();

                              if (favDocs.isEmpty) {
                                return const Text(
                                  'No favourites yet',
                                  style: TextStyle(color: Color(0xFF6C6C70), fontSize: 13),
                                );
                              }

                              return Column(
                                children: favDocs.map((doc) {
                                  final data = doc.data() as Map<String, dynamic>;
                                  final from = data['from'] as String? ?? '';
                                  final to = data['to'] as String? ?? '';
                                  final otherUser = from.toLowerCase() == currentUsername.toLowerCase()
                                      ? to
                                      : from;

                                  final cached = _usersCache[otherUser.toLowerCase()];
                                  final picUrl = cached?['profilePictureUrl'] as String? ?? '';
                                  final avatarHex = cached?['avatarColor'] as String? ?? '';

                                  return InkWell(
                                    onTap: () {
                                      setState(() => _isSidebarOpen = false);
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => ChatPage(
                                            currentUsername: currentUsername,
                                            targetUsername: otherUser,
                                            avatarColor: _parseColor(avatarHex),
                                            profilePictureUrl: picUrl,
                                            accentColor: accentColor,
                                          ),
                                        ),
                                      );
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 16,
                                            backgroundColor: _parseColor(avatarHex),
                                            backgroundImage: picUrl.isNotEmpty ? NetworkImage(picUrl) : null,
                                            child: picUrl.isEmpty
                                                ? Text(
                                                    otherUser.isNotEmpty ? otherUser[0].toUpperCase() : '?',
                                                    style: const TextStyle(color: Colors.white, fontSize: 12),
                                                  )
                                                : null,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              '@$otherUser',
                                              style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const Icon(Icons.favorite, color: Color(0xFFFF2D55), size: 13),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                          )
                        : const Text(
                            'No favourites yet',
                            style: TextStyle(color: Color(0xFF6C6C70), fontSize: 13),
                          ),
                  ),
                  _buildSidebarCard(
                    icon: Icons.star,
                    iconColor: Colors.amber,
                    title: 'Starred Messages',
                    child: currentUsername.isNotEmpty
                        ? StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collectionGroup('messages')
                                .where('starredBy', arrayContains: currentUsername)
                                .orderBy('timestamp', descending: true)
                                .limit(20)
                                .snapshots(),
                            builder: (context, snap) {
                              if (!snap.hasData || snap.data!.docs.isEmpty) {
                                return const Text(
                                  'No starred messages yet',
                                  style: TextStyle(color: Color(0xFF6C6C70), fontSize: 13),
                                );
                              }

                              final starredDocs = snap.data!.docs.where((doc) {
                                final data = doc.data() as Map<String, dynamic>;
                                final deletedFor = List<String>.from(data['deletedFor'] ?? []);
                                return !deletedFor.contains(currentUsername);
                              }).toList();

                              if (starredDocs.isEmpty) {
                                return const Text(
                                  'No starred messages yet',
                                  style: TextStyle(color: Color(0xFF6C6C70), fontSize: 13),
                                );
                              }

                              return Column(
                                children: starredDocs.map((doc) {
                                  final data = doc.data() as Map<String, dynamic>;
                                  final sender = data['sender'] as String? ?? '';
                                  final text = data['text'] as String? ?? '';
                                  final timestamp = data['timestamp'] as Timestamp?;
                                  final messageId = doc.id;

                                  final channelName = doc.reference.parent.parent?.id ?? '';

                                  String targetUser = '';
                                  if (channelName.startsWith('chat:')) {
                                    final parts = channelName.substring(5).split('-');
                                    if (parts.length == 2) {
                                      targetUser = parts[0].toLowerCase() == currentUsername.toLowerCase()
                                          ? parts[1]
                                          : parts[0];
                                    }
                                  }

                                  final cached = _usersCache[targetUser.toLowerCase()];
                                  final picUrl = cached?['profilePictureUrl'] as String? ?? '';
                                  final avatarHex = cached?['avatarColor'] as String? ?? '';

                                  final timeStr = timestamp != null
                                      ? DateFormat('MMM d, h:mm a').format(timestamp.toDate().toLocal())
                                      : '';

                                  return InkWell(
                                    onTap: () {
                                      setState(() => _isSidebarOpen = false);
                                      if (targetUser.isNotEmpty) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => ChatPage(
                                              currentUsername: currentUsername,
                                              targetUsername: targetUser,
                                              avatarColor: _parseColor(avatarHex),
                                              profilePictureUrl: picUrl,
                                              accentColor: accentColor,
                                              highlightMessageId: messageId,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          CircleAvatar(
                                            radius: 14,
                                            backgroundColor: sender.toLowerCase() == currentUsername.toLowerCase()
                                                ? _parseColor(_userData?['avatarColor'] ?? '')
                                                : _parseColor(avatarHex),
                                            backgroundImage: (sender.toLowerCase() != currentUsername.toLowerCase() &&
                                                    picUrl.isNotEmpty)
                                                ? NetworkImage(picUrl)
                                                : null,
                                            child: (sender.toLowerCase() == currentUsername.toLowerCase() ||
                                                    picUrl.isEmpty)
                                                ? Text(
                                                    sender.isNotEmpty ? sender[0].toUpperCase() : '?',
                                                    style: const TextStyle(color: Colors.white, fontSize: 10),
                                                  )
                                                : null,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        '@$sender',
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 12,
                                                          fontWeight: FontWeight.w500,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                    if (timeStr.isNotEmpty)
                                                      Text(
                                                        timeStr,
                                                        style: const TextStyle(
                                                          color: Color(0xFF6C6C70),
                                                          fontSize: 9,
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                                const SizedBox(height: 3),
                                                Text(
                                                  text,
                                                  style: const TextStyle(
                                                    color: Color(0xFF8E8E93),
                                                    fontSize: 11.5,
                                                  ),
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                          const Padding(
                                            padding: EdgeInsets.only(left: 6, top: 2),
                                            child: Icon(Icons.star, color: Colors.amber, size: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                          )
                        : const Text(
                            'No starred messages yet',
                            style: TextStyle(color: Color(0xFF6C6C70), fontSize: 13),
                          ),
                  ),
                  _buildSidebarCard(
                    icon: Icons.translate,
                    iconColor: const Color(0xFF0A84FF),
                    title: 'Translate Messages To',
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2E),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF3A3A3C), width: 1.0),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _userData?['selectedLanguage'] as String? ?? 'English',
                          dropdownColor: const Color(0xFF1C1C1E),
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                          isExpanded: true,
                          items: [
                            'English', 'Spanish', 'French', 'German', 'Hindi',
                            'Arabic', 'Japanese', 'Chinese', 'Portuguese', 'Italian',
                            'Russian', 'Telugu', 'Tamil', 'Bengali',
                          ].map((String lang) {
                            return DropdownMenuItem<String>(
                              value: lang,
                              child: Text(lang),
                            );
                          }).toList(),
                          onChanged: (String? newLang) async {
                            if (newLang == null) return;
                            setState(() {
                              if (_userData != null) {
                                _userData!['selectedLanguage'] = newLang;
                              }
                            });
                            try {
                              final snapshot = await FirebaseFirestore.instance
                                  .collection('userdetails')
                                  .where('email', isEqualTo: FirebaseAuth.instance.currentUser?.email)
                                  .limit(1)
                                  .get();
                              if (snapshot.docs.isNotEmpty) {
                                await snapshot.docs.first.reference.update({'selectedLanguage': newLang});
                              }
                            } catch (_) {}
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton(
                onPressed: () async {
                  await _updateOnlineStatus(false);
                  await FirebaseAuth.instance.signOut();
                  if (!mounted) return;
                  Navigator.pushReplacement(
                      context, MaterialPageRoute(builder: (c) => const AuthPage()));
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1C1C1E),
                  foregroundColor: accentColor,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: BorderSide(color: accentColor.withValues(alpha: 0.8), width: 1.2),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.logout_rounded, size: 18),
                    SizedBox(width: 8),
                    Text('Sign Out', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Premium Real-Time Chat Room Page powered by Ably
class ChatRoomPage extends StatefulWidget {
  final String currentUsername;
  final String targetUsername;
  final Color avatarColor;
  final String profilePictureUrl;
  final Color accentColor;

  const ChatRoomPage({
    super.key,
    required this.currentUsername,
    required this.targetUsername,
    required this.avatarColor,
    required this.profilePictureUrl,
    required this.accentColor,
  });

  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage> {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];

  StreamSubscription<Map<String, dynamic>>? _ablySubscription;
  StreamSubscription<QuerySnapshot>? _firestoreSubscription;
  late final String _channelName;
  bool _historyLoaded = false;

  @override
  void initState() {
    super.initState();
    _channelName = AblyService.instance.getChatChannelName(
      widget.currentUsername,
      widget.targetUsername,
    );
    _loadHistoryAndSubscribe();
  }

  Future<void> _loadHistoryAndSubscribe() async {
    // Load persisted messages from Firestore
    _firestoreSubscription =
        AblyService.instance.getMessageHistory(_channelName).listen((snapshot) {
      if (!_historyLoaded) {
        // Initial load — populate from Firestore
        final historyMessages = snapshot.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return {
            'sender': data['sender'] ?? '',
            'text': data['text'] ?? '',
            'timestamp': data['timestamp'],
          };
        }).toList();

        setState(() {
          _messages.clear();
          _messages.addAll(historyMessages);
          _historyLoaded = true;
        });

        _scrollToBottomAfterFrame();

        // Now subscribe to live Ably messages (only new ones after history load)
        _subscribeToAbly();
      } else {
        // Subsequent Firestore updates — sync latest if needed
        // (Ably handles real-time, Firestore is just for persistence)
      }
    });
  }

  void _subscribeToAbly() {
    if (!AblyService.instance.isInitialized) return;

    final channel = AblyService.instance.getChatChannel(
      widget.currentUsername,
      widget.targetUsername,
    );

    _ablySubscription =
        AblyService.instance.subscribeToMessages(channel).listen((msgData) {
      final sender = msgData['sender'] ?? '';
      final text = msgData['text'] ?? '';

      // Avoid duplicate from the publisher (we add our own messages immediately)
      // But we need messages from others
      if (sender != widget.currentUsername) {
        setState(() {
          _messages.add({
            'sender': sender,
            'text': text,
            'timestamp': msgData['timestamp'] ?? '',
          });
        });
        _scrollToBottomAfterFrame();
      }
    });
  }

  void _scrollToBottomAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;

    _msgController.clear();

    // Immediately add to local messages for instant UI feedback
    setState(() {
      _messages.add({
        'sender': widget.currentUsername,
        'text': text,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
    });
    _scrollToBottomAfterFrame();

    // Publish to Ably for real-time delivery to the other user
    if (AblyService.instance.isInitialized) {
      final channel = AblyService.instance.getChatChannel(
        widget.currentUsername,
        widget.targetUsername,
      );
      await AblyService.instance.publishMessage(
        channel: channel,
        sender: widget.currentUsername,
        text: text,
      );
    }

    // Persist to Firestore for message history
    await AblyService.instance.persistMessage(
      channelName: _channelName,
      sender: widget.currentUsername,
      text: text,
    );
  }

  @override
  void dispose() {
    _ablySubscription?.cancel();
    _firestoreSubscription?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF111111),
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: widget.accentColor, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: widget.avatarColor,
              backgroundImage: widget.profilePictureUrl.isNotEmpty
                  ? NetworkImage(widget.profilePictureUrl)
                  : null,
              child: widget.profilePictureUrl.isEmpty
                  ? Text(
                      widget.targetUsername.isNotEmpty
                          ? widget.targetUsername[0].toUpperCase()
                          : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Text(
              '@${widget.targetUsername}',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
        actions: [
          IconButton(icon: Icon(Icons.call, color: widget.accentColor), onPressed: () {}),
          IconButton(icon: Icon(Icons.videocam, color: widget.accentColor), onPressed: () {}),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Text(
                        'Send a message to start the conversation',
                        style: TextStyle(
                          color: const Color(0xFF8E8E93),
                          fontSize: 15,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        final bool isMe =
                            msg['sender'] == widget.currentUsername;

                        final timestampStr = formatLocalTimestamp(msg['timestamp']);

                        return Align(
                          alignment:
                              isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Column(
                            crossAxisAlignment:
                                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? widget.accentColor
                                      : const Color(0xFF1C1C1E),
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(16),
                                    topRight: const Radius.circular(16),
                                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                                    bottomRight: Radius.circular(isMe ? 4 : 16),
                                  ),
                                ),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.75,
                                ),
                                child: Text(
                                  msg['text'] ?? '',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 15),
                                ),
                              ),
                              if (timestampStr.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6, right: 6, bottom: 6),
                                  child: Text(
                                    timestampStr,
                                    style: const TextStyle(
                                      color: Color(0xFF8E8E93),
                                      fontSize: 9,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            // Message input container matching premium UI style
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: const Color(0xFF111111),
              child: Row(
                children: [
                  Icon(Icons.add_circle, color: widget.accentColor, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _msgController,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15),
                        decoration: const InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: TextStyle(
                              color: Color(0xFF8E8E93), fontSize: 15),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 10),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _sendMessage,
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: widget.accentColor,
                      child:
                          const Icon(Icons.send, color: Colors.white, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatLocalTimestamp(dynamic timestampVal) {
  if (timestampVal == null) return '';
  DateTime? dt;
  if (timestampVal is Timestamp) {
    dt = timestampVal.toDate();
  } else if (timestampVal is String) {
    dt = DateTime.tryParse(timestampVal);
  } else if (timestampVal is int) {
    dt = DateTime.fromMillisecondsSinceEpoch(timestampVal);
  }
  if (dt == null) return '';

  final localDt = dt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final dateOfMessage = DateTime(localDt.year, localDt.month, localDt.day);

  // Smart locale-aware time format (uses device locale)
  final timeStr = DateFormat.jm().format(localDt); // e.g. "11:30 AM" or "23:30"

  if (dateOfMessage == today) {
    return 'Today, $timeStr';
  } else if (dateOfMessage == yesterday) {
    return 'Yesterday, $timeStr';
  } else if (now.difference(localDt).inDays < 7) {
    // Within the last week — show day name + time
    final dayName = DateFormat.EEEE().format(localDt); // e.g. "Monday"
    return '$dayName, $timeStr';
  } else {
    // Older — full locale date + time
    final dateStr = DateFormat.yMMMd().format(localDt); // e.g. "May 27, 2026" or "27 mai 2026"
    return '$dateStr, $timeStr';
  }
}

