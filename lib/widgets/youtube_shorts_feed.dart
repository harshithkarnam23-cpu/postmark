import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// ═══════════════════════════════════════════════════════════════════
// CONSTANTS — Real Dynamic High-Quality YouTube Shorts IDs
// ═══════════════════════════════════════════════════════════════════
const Map<String, List<String>> _kCategoryShortsIds = {
  'trending': [
    '3QtKh9Cigb0', '5sAg3EFe48Y', 'fJw33GyM8FM', 'CjXd2Mo8nfM', 'wULy9SOwAzI', 'KREB7Lqn8zg', 'O65Bh9e4iPw', 't4VQzJtIvAM'
  ],
  'satisfying': [
    '2t2cig-Y4Y4', '18NaqLokQDw', 'm4PnfNHLonQ', 'YldEqGlZpLQ', 'Rpr1BUgskPo', 'KhYY-HkL5sY', 'JLoCY-tD_MQ', 'yNb7xTwGEbE'
  ],
  'tech': [
    'ZjxiNW-6aPU', 'UMpRRvZXbAY', 'W2tCuPdho4E', 'NUkp6hyuthM', 'LunekDfeMhc', 'KOmCrzzqT_o', 'Rk35D_2ZPzc', 'O_1RL-0klZw'
  ],
  'cooking': [
    'zelvF_WjwoA', 'bBpTzazM1x8', '_gX6z7VdSIM', 'TUvFMgbMAm8', 'sZrMFzsBACQ', 'kp2r4gS_rv4', 'D56BC6Dzerw', 'n5bQBJSFF8w'
  ],
  'gaming': [
    'qmYZpDrp1nk', 'gPdHuKhd5-s', '6j5lFR_hg-c', 'C6N4ooyREQ0', 'OkCYt696bNI', 'kBUir84CjHQ', 'nwBGVc09SoI', 'rZuR4TJ3Jeg'
  ],
  'racing': [
    'Z8SwOxx_BHU', 'HheuDdz995w', 'NP4RLipfkDY', 'DXWHYWC4l40', 'MU-DndmoF1c', '98P-4x_MVqk', '8NbHEKMW2ys', '3iFO1mmCJnM'
  ],
  'cinema': [
    'rjLWkoNOhqE', 'gNOmRSvGd3c', '_r5OYWPT6fc', 'lZ5jZI4p1ro', 'jiIh0N3FOF4', 'o_38Dk8zk-Y', 'F8K__ykNgFw', '4KC8OzvH7_o'
  ],
  'science': [
    'VwCveMqI4nc', 'H17zUuAjVfA', 'VMPtgint74M', 'R4T6G55Of50', 'fZTrTXVnN5Q', 'rEHLfHyktSo', 'PM2gHpO_Lsk', 'OPLkS9wLhow'
  ],
  'music': [
    '0Xgz-y4GKBY', 'wdQnfTGIGeY', 'dB8g_3N5r8U', 'DZpSvIkDH-c', 'Z91Uzzk9wMk', 'SbvQfiv2HUY', 'eaIazn9z0NA', 's-aCf_5aKds'
  ]
};

// ═══════════════════════════════════════════════════════════════════
// DATA MODEL — Heart Particle for confetti burst
// ═══════════════════════════════════════════════════════════════════
class _HeartParticle {
  final double velocityX;
  final double velocityY;
  final double baseScale;
  final Color color;

  _HeartParticle({
    required this.velocityX,
    required this.velocityY,
    required this.baseScale,
    required this.color,
  });
}

// ═══════════════════════════════════════════════════════════════════
// CONSTANTS — Trending Categories
// ═══════════════════════════════════════════════════════════════════
const List<Map<String, String>> _kTrendingCategories = [
  {'emoji': '🔥', 'label': 'Trending', 'query': 'trending'},
  {'emoji': '🎮', 'label': 'Gaming', 'query': 'gaming'},
  {'emoji': '🍳', 'label': 'Cooking', 'query': 'cooking'},
  {'emoji': '💻', 'label': 'Tech', 'query': 'tech'},
  {'emoji': '🏎️', 'label': 'Racing', 'query': 'racing'},
  {'emoji': '🎬', 'label': 'Cinema', 'query': 'cinema'},
  {'emoji': '🧪', 'label': 'Science', 'query': 'science'},
  {'emoji': '🎵', 'label': 'Music', 'query': 'music'},
];

// ═══════════════════════════════════════════════════════════════════
//  MAIN FEED WIDGET
// ═══════════════════════════════════════════════════════════════════
class YoutubeShortsFeed extends StatefulWidget {
  final String currentUsername;
  final Color accentColor;
  final bool isTabActive;
  final String searchQuery;

  const YoutubeShortsFeed({
    super.key,
    required this.currentUsername,
    required this.accentColor,
    required this.isTabActive,
    required this.searchQuery,
  });

  @override
  State<YoutubeShortsFeed> createState() => _YoutubeShortsFeedState();
}

class _YoutubeShortsFeedState extends State<YoutubeShortsFeed>
    with TickerProviderStateMixin {
  // ── Core State ─────────────────────────────────────────────────
  int _currentPageIndex = 0;
  bool _isMuted = false;

  // ── Category Weights (Mocked for now since we use static files)
  final Map<String, double> _queryWeights = {
    'trending': 1.0, 'gaming': 1.0, 'cooking': 1.0, 'tech': 1.0,
    'racing': 1.0, 'cinema': 1.0, 'science': 1.0, 'music': 1.0,
  };

  // ── Onboarding ─────────────────────────────────────────────────
  final Set<String> _selectedOnboardingCategories = {};
  bool _showOnboarding = false;
  late AnimationController _onboardingController;
  late AnimationController _shimmerController;

  // ── Paging ─────────────────────────────────────────────────────
  late DateTime _pageViewStartTime;
  late PageController _pageController;
  bool _isLoadingNextBatch = false;
  bool _isScrolling = false;

  // ── Data ───────────────────────────────────────────────────────
  StreamSubscription<QuerySnapshot>? _firestoreSubscription;
  List<Map<String, dynamic>> _firestoreShorts = [];
  final List<Map<String, dynamic>> _mockedShorts = [];
  List<Map<String, dynamic>> _allShorts = [];

  // ── New: Feed Mode & Discovery ─────────────────────────────────
  int _feedMode = 0; // 0 = For You, 1 = Following
  String? _activeTrendingCategory;
  bool _showTrendingChips = false;
  Set<String> _friendUsernames = {};
  Set<String> _bookmarkedVideoIds = {};
  final Set<String> _watchedVideoIds = {};

  @override
  void initState() {
    super.initState();
    _pageViewStartTime = DateTime.now();
    _pageController = PageController();

    _onboardingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _loadQueryWeights();
    _listenToFirestoreShorts();
    _loadFriendsList();
    _loadBookmarks();
    _fetchNextBatch(); // Generate first batch of fake videos
  }

  @override
  void dispose() {
    _firestoreSubscription?.cancel();
    _pageController.dispose();
    _onboardingController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant YoutubeShortsFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchQuery != oldWidget.searchQuery) {
      setState(() {
        _mockedShorts.clear();
        _allShorts.clear();
        _currentPageIndex = 0;
        _pageViewStartTime = DateTime.now();
      });
      _fetchNextBatch();
    }
  }

  void _handleMouseScroll(PointerScrollEvent event) {
    if (_isScrolling) return;
    if (event.scrollDelta.dy > 10) {
      final nextPage = _currentPageIndex + 1;
      if (nextPage < _displayShorts.length) {
        _isScrolling = true;
        _pageController
            .animateToPage(nextPage,
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeInOutCubic)
            .then((_) => _isScrolling = false);
      }
    } else if (event.scrollDelta.dy < -10) {
      final prevPage = _currentPageIndex - 1;
      if (prevPage >= 0) {
        _isScrolling = true;
        _pageController
            .animateToPage(prevPage,
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeInOutCubic)
            .then((_) => _isScrolling = false);
      }
    }
  }

  void _handlePlayerError(String shortId) {
    debugPrint("Auto-removing broken video: $shortId");
    setState(() {
      _allShorts.removeWhere((s) => s['id'] == shortId);
      _mockedShorts.removeWhere((s) => s['id'] == shortId);
    });
    if (_displayShorts.length <= 2) {
      _fetchNextBatch();
    }
  }

  Future<void> _loadQueryWeights() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('shorts_weights')
          .doc(widget.currentUsername)
          .get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data()!['weights'] as Map<String, dynamic>?;
        if (data != null) {
          setState(() {
            data.forEach((key, value) {
              if (_queryWeights.containsKey(key)) {
                _queryWeights[key] = (value as num).toDouble();
              }
            });
          });
        }
      } else {
        setState(() => _showOnboarding = true);
        _onboardingController.forward();
      }
    } catch (e) {
      debugPrint("Error loading shorts weights: $e");
    }
  }

  void _updateCategoryWeight(String? category, double delta) async {
    if (category == null || category == 'custom_upload') return;
    if (!_queryWeights.containsKey(category)) return;
    setState(() {
      double w = (_queryWeights[category] ?? 1.0) + delta;
      _queryWeights[category] = w.clamp(0.1, 5.0);
    });
    _saveWeightsToFirestore();
  }

  void _saveWeightsToFirestore() async {
    try {
      await FirebaseFirestore.instance
          .collection('shorts_weights')
          .doc(widget.currentUsername)
          .set({
        'weights': _queryWeights,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Error saving weights: $e");
    }
  }

  void _loadFriendsList() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('relationships')
          .where('status', isEqualTo: 'friends')
          .get();
      final friends = <String>{};
      final me = widget.currentUsername.toLowerCase();
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final from = (data['from'] as String? ?? '').toLowerCase();
        final to = (data['to'] as String? ?? '').toLowerCase();
        if (from == me) friends.add(to);
        if (to == me) friends.add(from);
      }
      if (mounted) setState(() => _friendUsernames = friends);
    } catch (e) {
      debugPrint("Error loading friends list: $e");
    }
  }

  void _loadBookmarks() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('saved_shorts')
          .doc(widget.currentUsername)
          .collection('videos')
          .get();
      if (mounted) {
        setState(() {
          _bookmarkedVideoIds = snapshot.docs.map((d) => d.id).toSet();
        });
      }
    } catch (e) {
      debugPrint("Error loading bookmarks: $e");
    }
  }

  Future<void> _toggleBookmark(String videoId, Map<String, dynamic> data) async {
    final ref = FirebaseFirestore.instance
        .collection('saved_shorts')
        .doc(widget.currentUsername)
        .collection('videos')
        .doc(videoId);
    if (_bookmarkedVideoIds.contains(videoId)) {
      await ref.delete();
      setState(() => _bookmarkedVideoIds.remove(videoId));
    } else {
      await ref.set({
        'videoId': videoId,
        'title': data['title'] ?? '',
        'creator': data['creator'] ?? '',
        'savedAt': FieldValue.serverTimestamp(),
      });
      setState(() => _bookmarkedVideoIds.add(videoId));
    }
  }

  void _listenToFirestoreShorts() {
    _firestoreSubscription = FirebaseFirestore.instance
        .collection('shorts')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      _firestoreShorts = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
      _mergeAndSyncShorts();
    });
  }

  void _mergeAndSyncShorts() {
    final List<Map<String, dynamic>> merged = [];
    final Set<String> ids = {};
    for (var item in _firestoreShorts) {
      final vid = item['videoId'] as String? ?? '';
      if (vid.isNotEmpty && !ids.contains(vid)) {
        item['category'] ??= 'custom_upload';
        merged.add(item);
        ids.add(vid);
      }
    }
    for (var item in _mockedShorts) {
      final vid = item['videoId'] as String? ?? '';
      if (vid.isNotEmpty && !ids.contains(vid)) {
        merged.add(item);
        ids.add(vid);
      }
    }
    if (mounted) setState(() => _allShorts = merged);
  }

  Future<void> _fetchNextBatch() async {
    if (_isLoadingNextBatch) return;
    if (mounted) setState(() => _isLoadingNextBatch = true);

    await Future.delayed(const Duration(milliseconds: 400));
    final random = math.Random();
    
    final query = _activeTrendingCategory ?? 
        (widget.searchQuery.isNotEmpty ? widget.searchQuery : 'trending');

    final idsForCat = _kCategoryShortsIds[query] ?? _kCategoryShortsIds['trending']!;
    final List<String> shuffledIds = List.from(idsForCat)..shuffle(random);

    final List<Map<String, dynamic>> items = [];
    final int count = math.min(5, shuffledIds.length);
    for (int i = 0; i < count; i++) {
      final yId = shuffledIds[i];
      final vid = 'yt_$yId';
      items.add({
        'id': 'scraped_$vid',
        'videoId': yId, // Storing raw YouTube Video ID here!
        'title': _generateTitleForQuery(query),
        'creator': _generateCreatorForQuery(query, vid),
        'likes': <String>[],
        'commentCount': random.nextInt(400),
        'createdAt': Timestamp.now(),
        'isScraped': true,
        'category': query,
        'viewCount': random.nextInt(50000) + 1000,
      });
    }

    _mockedShorts.addAll(items);
    _mergeAndSyncShorts();
    if (mounted) setState(() => _isLoadingNextBatch = false);
  }

  String _generateTitleForQuery(String query) {
    final tags = ['#shorts', '#viral', '#trending', '#aesthetic']..shuffle();
    if (query.contains('tech')) return "Mind-blowing tech 🤯💻 ${tags.take(2).join(' ')}";
    if (query.contains('cooking')) return "Delicious recipe 🍕🔥 ${tags.take(2).join(' ')}";
    if (query.contains('science')) return "Science is amazing 🔬✨ ${tags.take(2).join(' ')}";
    if (query.contains('racing') || query.contains('formula')) return "Racing thrills 🏎️🏁 ${tags.take(2).join(' ')}";
    if (query.contains('gaming')) return "Epic gaming moment 🎮🔥 ${tags.take(2).join(' ')}";
    if (query.contains('music')) return "Incredible performance 🎵🎤 ${tags.take(2).join(' ')}";
    return "Check this out 🌟🔥 ${tags.take(2).join(' ')}";
  }

  String _generateCreatorForQuery(String query, String videoId) {
    final i = videoId.codeUnitAt(0) % 5;
    if (query.contains('tech')) return ['MKBHD', 'TechInsider', 'GadgetLab', 'FutureTech', 'ByteSize'][i];
    if (query.contains('cooking')) return ['GordonRamsay', 'FoodieReels', 'ChefSecrets', 'BakingJoy', 'YummyEats'][i];
    if (query.contains('science')) return ['Veritasium', 'SmarterEveryDay', 'SciShow', 'MinutePhysics', 'Vsauce'][i];
    if (query.contains('racing')) return ['F1Official', 'MotorsportTV', 'RaceHighlights', 'SpeedKings', 'TrackDay'][i];
    if (query.contains('gaming')) return ['PewDiePie', 'MrBeast', 'Ninja', 'Shroud', 'xQc'][i];
    return ['CreatorHub', 'DailyVids', 'ShortsTrend', 'ViralClips', 'TrendingNow'][i];
  }

  List<Map<String, dynamic>> get _displayShorts {
    List<Map<String, dynamic>> shorts;
    if (_feedMode == 1) {
      shorts = _allShorts.where((s) {
        final creator = (s['creator'] as String? ?? '').toLowerCase();
        return _friendUsernames.contains(creator);
      }).toList();
    } else {
      shorts = _allShorts;
    }
    if (widget.searchQuery.isNotEmpty) {
      final q = widget.searchQuery.toLowerCase();
      shorts = shorts.where((s) {
        final title = (s['title'] as String? ?? '').toLowerCase();
        final creator = (s['creator'] as String? ?? '').toLowerCase();
        return title.contains(q) || creator.contains(q);
      }).toList();
    }
    return shorts;
  }

  void _selectTrendingCategory(String query) {
    setState(() {
      _activeTrendingCategory = query;
      _mockedShorts.clear();
      _allShorts.clear();
      _currentPageIndex = 0;
    });
    _fetchNextBatch();
  }

  void _clearTrendingCategory() {
    setState(() {
      _activeTrendingCategory = null;
      _mockedShorts.clear();
      _allShorts.clear();
      _currentPageIndex = 0;
    });
    _fetchNextBatch();
  }

  Widget _buildOnboardingOverlay() {
    final titleFade = CurvedAnimation(
        parent: _onboardingController,
        curve: const Interval(0.0, 0.25, curve: Curves.easeOut));
    final subtitleFade = CurvedAnimation(
        parent: _onboardingController,
        curve: const Interval(0.12, 0.35, curve: Curves.easeOut));
    final chipsFade = CurvedAnimation(
        parent: _onboardingController,
        curve: const Interval(0.25, 0.6, curve: Curves.easeOutCubic));
    final buttonFade = CurvedAnimation(
        parent: _onboardingController,
        curve: const Interval(0.55, 0.85, curve: Curves.easeOut));

    return Positioned.fill(
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: AnimatedBuilder(
            animation: _onboardingController,
            builder: (context, _) {
              return Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.92),
                      const Color(0xFF0D0D1A).withValues(alpha: 0.95),
                      Colors.black.withValues(alpha: 0.92),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(),
                    FadeTransition(
                      opacity: titleFade,
                      child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0, 0.4), end: Offset.zero)
                            .animate(titleFade),
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(colors: [
                              widget.accentColor,
                              widget.accentColor.withValues(alpha: 0.6),
                            ]),
                          ),
                          child: const Icon(Icons.auto_awesome_rounded,
                              color: Colors.white, size: 32),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeTransition(
                      opacity: titleFade,
                      child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0, 0.3), end: Offset.zero)
                            .animate(titleFade),
                        child: const Text('Personalize Your Feed',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    FadeTransition(
                      opacity: subtitleFade,
                      child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0, 0.3), end: Offset.zero)
                            .animate(subtitleFade),
                        child: const Text(
                          'Pick what you love. Our algorithm learns from every swipe, like, and second you watch.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 14, height: 1.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 36),
                    FadeTransition(
                      opacity: chipsFade,
                      child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0, 0.25), end: Offset.zero)
                            .animate(chipsFade),
                        child: StatefulBuilder(
                          builder: (context, setLocal) {
                            return Wrap(
                              spacing: 10,
                              runSpacing: 12,
                              alignment: WrapAlignment.center,
                              children: _queryWeights.keys.map((query) {
                                final isSel = _selectedOnboardingCategories.contains(query);
                                return GestureDetector(
                                  onTap: () {
                                    setLocal(() {
                                      if (isSel) {
                                        _selectedOnboardingCategories.remove(query);
                                      } else {
                                        _selectedOnboardingCategories.add(query);
                                      }
                                    });
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 250),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isSel
                                          ? widget.accentColor.withValues(alpha: 0.25)
                                          : Colors.white.withValues(alpha: 0.06),
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: isSel
                                            ? widget.accentColor
                                            : Colors.white.withValues(alpha: 0.12),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Text(query.toUpperCase(),
                                        style: TextStyle(
                                          color: isSel ? Colors.white : Colors.white60,
                                          fontSize: 13,
                                          fontWeight:
                                              isSel ? FontWeight.bold : FontWeight.normal,
                                        )),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ),
                    ),
                    const Spacer(),
                    FadeTransition(
                      opacity: buttonFade,
                      child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0, 0.4), end: Offset.zero)
                            .animate(buttonFade),
                        child: SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: Stack(children: [
                            Positioned.fill(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: widget.accentColor,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(27)),
                                  elevation: 0,
                                ),
                                onPressed: () async {
                                  for (var q in _queryWeights.keys) {
                                    _queryWeights[q] =
                                        _selectedOnboardingCategories.contains(q) ? 3.5 : 0.5;
                                  }
                                  _saveWeightsToFirestore();
                                  setState(() {
                                    _showOnboarding = false;
                                    _mockedShorts.clear();
                                    _allShorts.clear();
                                  });
                                  _fetchNextBatch();
                                },
                                child: const Text('Start Watching',
                                    style: TextStyle(
                                        fontSize: 16, fontWeight: FontWeight.bold)),
                              ),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(27),
                                  child: AnimatedBuilder(
                                    animation: _shimmerController,
                                    builder: (context, _) {
                                      final v = _shimmerController.value;
                                      return Container(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              Colors.transparent,
                                              Colors.white.withValues(alpha: 0.15),
                                              Colors.transparent,
                                            ],
                                            stops: [
                                              (v - 0.3).clamp(0.0, 1.0),
                                              v.clamp(0.0, 1.0),
                                              (v + 0.3).clamp(0.0, 1.0),
                                            ],
                                            begin: Alignment.centerLeft,
                                            end: Alignment.centerRight,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingHeader() {
    return Positioned(
      top: 50, // Added padding to account for hidden appbar
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(25),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _headerSegment('Following', 1),
                  const SizedBox(width: 2),
                  _headerSegment('For You', 0),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: GestureDetector(
                onTap: () => setState(() => _showTrendingChips = !_showTrendingChips),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _showTrendingChips
                        ? widget.accentColor.withValues(alpha: 0.3)
                        : Colors.white.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                  ),
                  child: Icon(
                    _showTrendingChips ? Icons.close_rounded : Icons.explore_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerSegment(String label, int mode) {
    final isSel = _feedMode == mode;
    return GestureDetector(
      onTap: () {
        if (_feedMode == mode) return;
        setState(() {
          _feedMode = mode;
          _currentPageIndex = 0;
        });
        if (mode == 0 && _displayShorts.isEmpty) _fetchNextBatch();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: isSel ? Colors.white.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Text(label,
            style: TextStyle(
              color: isSel ? Colors.white : Colors.white54,
              fontSize: 15,
              fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
            )),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shorts = _displayShorts;

    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          if (shorts.isEmpty && _isLoadingNextBatch)
            Center(
                child: CircularProgressIndicator(
                    color: widget.accentColor, strokeWidth: 2.5))
          else if (shorts.isEmpty && !_showOnboarding)
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                    _feedMode == 1 ? Icons.people_outline_rounded : Icons.video_library_outlined,
                    color: Colors.white24, size: 56),
                const SizedBox(height: 16),
                Text(
                  _feedMode == 1
                      ? 'No shorts from friends yet'
                      : 'No shorts found',
                  style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
                ),
              ]),
            )
          else
            Listener(
              onPointerSignal: (sig) {
                if (sig is PointerScrollEvent) {
                  GestureBinding.instance.pointerSignalResolver
                      .register(sig, (event) => _handleMouseScroll(sig));
                }
              },
              child: PageView.builder(
                controller: _pageController,
                scrollBehavior: AppScrollBehavior(),
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                scrollDirection: Axis.vertical,
                itemCount: shorts.length,
                onPageChanged: (index) {
                  final prevIndex = _currentPageIndex;
                  final now = DateTime.now();
                  final dur = now.difference(_pageViewStartTime).inSeconds;
                  if (prevIndex < shorts.length) {
                    final cat = shorts[prevIndex]['category'] as String?;
                    if (dur >= 8) {
                      _updateCategoryWeight(cat, 0.2);
                    } else if (dur < 3) {
                      _updateCategoryWeight(cat, -0.2);
                    }
                    final vid = shorts[prevIndex]['videoId'] as String? ?? '';
                    if (vid.isNotEmpty) _watchedVideoIds.add(vid);
                  }
                  setState(() {
                    _currentPageIndex = index;
                    _pageViewStartTime = now;
                  });
                  if (index >= shorts.length - 3) _fetchNextBatch();
                },
                itemBuilder: (context, index) {
                  final data = shorts[index];
                  final videoUrl = data['videoId'] as String? ?? '';
                  final shortId = data['id'] as String;
                  final creator = (data['creator'] as String? ?? '').toLowerCase();
                  return NativeVideoPlayerItem(
                    key: ValueKey<String>(shortId),
                    videoUrl: videoUrl,
                    shortId: shortId,
                    shortData: data,
                    currentUsername: widget.currentUsername,
                    isActive: index == _currentPageIndex,
                    isTabActive: widget.isTabActive,
                    isMuted: _isMuted,
                    onMuteToggle: () => setState(() => _isMuted = !_isMuted),
                    accentColor: widget.accentColor,
                    onInteraction: _updateCategoryWeight,
                    onPlayerError: () => _handlePlayerError(shortId),
                    isFriend: _friendUsernames.contains(creator),
                    isBookmarked: _bookmarkedVideoIds.contains(videoUrl),
                    isWatched: _watchedVideoIds.contains(videoUrl),
                    onBookmarkToggle: () => _toggleBookmark(videoUrl, data),
                  );
                },
              ),
            ),

          if (!_showOnboarding && _showTrendingChips)
            Positioned(
              top: 100, // Adjusted below the floating header
              left: 0,
              right: 0,
              child: SizedBox(
                height: 42,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _kTrendingCategories.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      final isActive = _activeTrendingCategory == null;
                      return GestureDetector(
                        onTap: () { if (!isActive) _clearTrendingCategory(); },
                        child: _trendingChip('✨ All', isActive),
                      );
                    }
                    final cat = _kTrendingCategories[index - 1];
                    final isActive = _activeTrendingCategory == cat['query'];
                    return GestureDetector(
                      onTap: () => _selectTrendingCategory(cat['query']!),
                      child: _trendingChip('${cat['emoji']} ${cat['label']}', isActive),
                    );
                  },
                ),
              ),
            ),

          if (!_showOnboarding) _buildFloatingHeader(),

          if (_showOnboarding) _buildOnboardingOverlay(),
        ],
      ),
    );
  }

  Widget _trendingChip(String label, bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isActive
            ? widget.accentColor.withValues(alpha: 0.3)
            : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: isActive ? widget.accentColor : Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(label,
          style: TextStyle(
              color: isActive ? Colors.white : Colors.white60,
              fontSize: 13,
              fontWeight: FontWeight.w600)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  INDIVIDUAL NATIVE REEL PLAYER ITEM (Uses video_player instead of Youtube)
// ═══════════════════════════════════════════════════════════════════
class NativeVideoPlayerItem extends StatefulWidget {
  final String videoUrl;
  final String shortId;
  final Map<String, dynamic> shortData;
  final String currentUsername;
  final bool isActive;
  final bool isTabActive;
  final bool isMuted;
  final VoidCallback onMuteToggle;
  final Color accentColor;
  final Function(String? category, double delta) onInteraction;
  final VoidCallback onPlayerError;
  final bool isFriend;
  final bool isBookmarked;
  final bool isWatched;
  final VoidCallback onBookmarkToggle;

  const NativeVideoPlayerItem({
    super.key,
    required this.videoUrl,
    required this.shortId,
    required this.shortData,
    required this.currentUsername,
    required this.isActive,
    required this.isTabActive,
    required this.isMuted,
    required this.onMuteToggle,
    required this.accentColor,
    required this.onInteraction,
    required this.onPlayerError,
    required this.isFriend,
    required this.isBookmarked,
    required this.isWatched,
    required this.onBookmarkToggle,
  });

  @override
  State<NativeVideoPlayerItem> createState() => _NativeVideoPlayerItemState();
}

class _NativeVideoPlayerItemState extends State<NativeVideoPlayerItem>
    with TickerProviderStateMixin {
  VideoPlayerController? _controller;
  bool _isControllerInitialized = false;
  bool _showCenterHeart = false;
  bool _showMuteIndicator = false;
  bool _showPauseIndicator = false;
  bool _isSubscribed = false;
  double _progressFraction = 0.0;

  late AnimationController _discRotationController;
  late AnimationController _heartParticleController;
  List<_HeartParticle> _heartParticles = [];

  int _watchSeconds = 0;
  Timer? _watchTimer;
  bool _showBookmarkPop = false;

  @override
  void initState() {
    super.initState();
    _discRotationController = AnimationController(
        vsync: this, duration: const Duration(seconds: 4));
    _heartParticleController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));

    // Pre-initialize the controller so it's ready instantly when swiped into view
    _initializeController();
    
    if (widget.isActive && widget.isTabActive) {
      _startWatchTimer();
    }
  }

  Future<void> _initializeController() async {
    if (_isControllerInitialized) return;
    
    String finalUrl = widget.videoUrl;
    YoutubeExplode? yt;
    
    try {
      if (!finalUrl.startsWith('http://') && !finalUrl.startsWith('https://')) {
        yt = YoutubeExplode();
        var manifest = await yt.videos.streamsClient.getManifest(widget.videoUrl);
        var streamInfo = manifest.muxed.withHighestBitrate();
        finalUrl = streamInfo.url.toString();
      }
      
      _controller = VideoPlayerController.networkUrl(Uri.parse(finalUrl));
      _controller!.addListener(_videoPlayerListener);
      
      await _controller!.initialize();
      await _controller!.setLooping(true);
      await _controller!.setVolume(widget.isMuted ? 0.0 : 1.0);
      _isControllerInitialized = true;
      if (mounted) {
        setState(() {});
        _controller!.play();
        _discRotationController.repeat();
      }
    } catch (e) {
      debugPrint("Native Video Error for ${widget.videoUrl}: $e");
      widget.onPlayerError();
    } finally {
      yt?.close();
    }
  }

  void _disposeController() {
    if (!_isControllerInitialized || _controller == null) return;
    
    // Graceful teardown to prevent libmdk.so null pointer dereference
    final ctrl = _controller!;
    _controller = null;
    _isControllerInitialized = false;
    
    ctrl.removeListener(_videoPlayerListener);
    // Let it pause gracefully in the background, then dispose
    ctrl.pause().then((_) => ctrl.dispose()).catchError((_) => ctrl.dispose());
    
    _discRotationController.stop();
  }

  void _videoPlayerListener() {
    if (mounted && _controller != null && _controller!.value.isInitialized) {
      final v = _controller!.value;
      if (v.hasError) widget.onPlayerError();
      if (v.duration.inMilliseconds > 0) {
        setState(() {
          _progressFraction = v.position.inMilliseconds / v.duration.inMilliseconds;
        });
      }
    }
  }

  void _startWatchTimer() {
    _watchTimer?.cancel();
    _watchSeconds = 0;
    _watchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _watchSeconds++);
    });
  }

  void _stopWatchTimer() {
    _watchTimer?.cancel();
  }

  @override
  void didUpdateWidget(covariant NativeVideoPlayerItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldPlay = widget.isActive && widget.isTabActive;
    final wasPlaying = oldWidget.isActive && oldWidget.isTabActive;
    if (shouldPlay != wasPlaying) {
      if (shouldPlay) {
        if (!_isControllerInitialized) {
          _initializeController();
        } else {
          _controller?.play();
          _discRotationController.repeat();
        }
        _startWatchTimer();
      } else {
        _controller?.pause();
        _discRotationController.stop();
        _stopWatchTimer();
      }
    }
    if (_isControllerInitialized && _controller != null) {
      if (widget.isMuted != oldWidget.isMuted) {
        _controller!.setVolume(widget.isMuted ? 0.0 : 1.0);
      }
    }
  }

  @override
  void dispose() {
    _disposeController();
    _stopWatchTimer();
    _discRotationController.dispose();
    _heartParticleController.dispose();
    super.dispose();
  }

  void _triggerDoubleTapLike() {
    setState(() => _showCenterHeart = true);
    Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showCenterHeart = false);
    });

    _spawnHeartParticles();

    final likes = List<String>.from(widget.shortData['likes'] ?? []);
    if (!likes.contains(widget.currentUsername)) _toggleLike();
  }

  void _spawnHeartParticles() {
    final random = math.Random();
    _heartParticles = List.generate(8, (_) {
      return _HeartParticle(
        velocityX: (random.nextDouble() - 0.5) * 220,
        velocityY: -(random.nextDouble() * 180 + 80),
        baseScale: random.nextDouble() * 0.4 + 0.4,
        color: [
          const Color(0xFFFF2D55),
          const Color(0xFFFF6B6B),
          const Color(0xFFFF85A1),
          const Color(0xFFFFB3C1),
          const Color(0xFFFF4081),
        ][random.nextInt(5)],
      );
    });
    _heartParticleController.forward(from: 0.0);
  }

  void _toggleMute() {
    widget.onMuteToggle();
    setState(() => _showMuteIndicator = true);
    Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showMuteIndicator = false);
    });
  }

  void _toggleLike() {
    final isScraped = widget.shortData['isScraped'] as bool? ?? false;
    if (isScraped) {
      final likes = List<String>.from(widget.shortData['likes'] ?? []);
      setState(() {
        if (likes.contains(widget.currentUsername)) {
          likes.remove(widget.currentUsername);
          widget.onInteraction(widget.shortData['category'] as String?, -0.5);
        } else {
          likes.add(widget.currentUsername);
          widget.onInteraction(widget.shortData['category'] as String?, 0.5);
        }
        widget.shortData['likes'] = likes;
      });
      return;
    }
    final docRef = FirebaseFirestore.instance.collection('shorts').doc(widget.shortId);
    final likes = List<String>.from(widget.shortData['likes'] ?? []);
    final isLiked = likes.contains(widget.currentUsername);
    if (isLiked) {
      docRef.update({'likes': FieldValue.arrayRemove([widget.currentUsername])});
      widget.onInteraction(widget.shortData['category'] as String?, -0.5);
    } else {
      docRef.update({'likes': FieldValue.arrayUnion([widget.currentUsername])});
      widget.onInteraction(widget.shortData['category'] as String?, 0.5);
    }
  }

  void _triggerBookmark() {
    widget.onBookmarkToggle();
    setState(() => _showBookmarkPop = true);
    Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showBookmarkPop = false);
    });
  }

  void _shareShort() {
    Clipboard.setData(ClipboardData(text: widget.videoUrl));
    widget.onInteraction(widget.shortData['category'] as String?, 0.4);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Video link copied to clipboard!'),
      backgroundColor: Color(0xFF1C1C1E),
      duration: Duration(seconds: 2),
    ));
  }

  void _showCommentsBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final commentController = TextEditingController();
        final isScraped = widget.shortData['isScraped'] as bool? ?? false;
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (_, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF1C1C1E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(children: [
                Center(
                  child: Container(
                    width: 40, height: 5,
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2.5)),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 8.0),
                  child: Text('Comments',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ),
                const Divider(color: Colors.white12),
                Expanded(
                  child: isScraped
                      ? _buildScrapedCommentsList(scrollController)
                      : _buildFirestoreCommentsList(scrollController),
                ),
                const Divider(color: Colors.white12),
                Padding(
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                      left: 16, right: 16, top: 8),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: commentController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Add a comment...',
                          hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none),
                          fillColor: const Color(0xFF2C2C2E),
                          filled: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(Icons.send_rounded, color: widget.accentColor),
                      onPressed: () async {
                        final txt = commentController.text.trim();
                        if (txt.isEmpty) return;
                        commentController.clear();
                        widget.onInteraction(
                            widget.shortData['category'] as String?, 0.3);
                        if (isScraped) {
                          setState(() {
                            final comments = List<Map<String, dynamic>>.from(
                                widget.shortData['scrapedComments'] ?? []);
                            comments.insert(0, {
                              'username': widget.currentUsername,
                              'text': txt,
                              'createdAt': Timestamp.now(),
                            });
                            widget.shortData['scrapedComments'] = comments;
                            widget.shortData['commentCount'] =
                                (widget.shortData['commentCount'] ?? 0) + 1;
                          });
                        } else {
                          try {
                            await FirebaseFirestore.instance
                                .collection('shorts')
                                .doc(widget.shortId)
                                .collection('comments')
                                .add({
                              'username': widget.currentUsername,
                              'text': txt,
                              'createdAt': FieldValue.serverTimestamp(),
                              'avatarColor': '',
                              'profilePictureUrl': '',
                            });
                            FirebaseFirestore.instance
                                .collection('shorts')
                                .doc(widget.shortId)
                                .update({'commentCount': FieldValue.increment(1)});
                          } catch (_) {}
                        }
                      },
                    ),
                  ]),
                ),
              ]),
            );
          },
        );
      },
    );
  }

  Widget _buildFirestoreCommentsList(ScrollController sc) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('shorts')
          .doc(widget.shortId)
          .collection('comments')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('Error loading comments', style: TextStyle(color: Colors.grey)));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final comments = snapshot.data!.docs;
        if (comments.isEmpty) return const Center(child: Text('No comments yet. Be the first!', style: TextStyle(color: Colors.grey, fontSize: 14)));
        return ListView.builder(
          controller: sc,
          padding: const EdgeInsets.all(16),
          itemCount: comments.length,
          itemBuilder: (ctx, i) {
            final c = comments[i].data() as Map<String, dynamic>;
            return _buildCommentRow(c['username'] ?? 'user', c['text'] ?? '', c['createdAt'] as Timestamp?, c['avatarColor'] ?? '', c['profilePictureUrl'] ?? '');
          },
        );
      },
    );
  }

  Widget _buildScrapedCommentsList(ScrollController sc) {
    final list = List<Map<String, dynamic>>.from(widget.shortData['scrapedComments'] ?? []);
    if (list.isEmpty) return const Center(child: Text('No comments yet. Be the first!', style: TextStyle(color: Colors.grey, fontSize: 14)));
    return ListView.builder(
      controller: sc,
      padding: const EdgeInsets.all(16),
      itemCount: list.length,
      itemBuilder: (ctx, i) {
        final c = list[i];
        return _buildCommentRow(c['username'] ?? 'user', c['text'] ?? '', c['createdAt'] as Timestamp?, '', '');
      },
    );
  }

  Widget _buildCommentRow(String username, String text, Timestamp? ts, String hex, String pic) {
    String timeStr = 'now';
    if (ts != null) {
      final d = DateTime.now().difference(ts.toDate());
      if (d.inHours < 1) { timeStr = '${d.inMinutes}m'; }
      else if (d.inDays < 1) { timeStr = '${d.inHours}h'; }
      else { timeStr = '${d.inDays}d'; }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: hex.isNotEmpty ? Color(int.parse(hex)) : _avatarColor(username),
          backgroundImage: pic.isNotEmpty ? NetworkImage(pic) : null,
          child: pic.isEmpty ? Text(username.isNotEmpty ? username[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontSize: 13)) : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(username, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text(timeStr, style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ]),
            const SizedBox(height: 3),
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }

  void _showCreatorProfileSheet() {
    final creator = widget.shortData['creator'] as String? ?? 'Creator';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Color(0xFF1C1C1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Center(
              child: Container(
                width: 40, height: 5,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2.5)),
              ),
            ),
            CircleAvatar(
              radius: 40,
              backgroundColor: _avatarColor(creator),
              child: Text(creator.isNotEmpty ? creator[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('@$creator', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              if (widget.isFriend) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: const Color(0xFF14301B), borderRadius: BorderRadius.circular(8)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.check_circle, color: Color(0xFF30D158), size: 12),
                    SizedBox(width: 4),
                    Text('Friend', style: TextStyle(color: Color(0xFF30D158), fontSize: 11, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ],
            ]),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _profileStat('Shorts', '—'),
              Container(width: 1, height: 30, color: Colors.white12, margin: const EdgeInsets.symmetric(horizontal: 24)),
              _profileStat('Likes', '—'),
            ]),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.accentColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text(widget.isFriend ? 'Message' : 'View Profile', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 12),
          ]),
        );
      },
    );
  }

  Widget _profileStat(String label, String value) {
    return Column(children: [
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
    ]);
  }

  Color _avatarColor(String name) {
    if (name.isEmpty) return Colors.blue;
    int hash = 0;
    for (int i = 0; i < name.length; i++) hash = name.codeUnitAt(i) + ((hash << 5) - hash);
    const colors = [
      Color(0xFFFF3B30), Color(0xFFFF9500), Color(0xFFFFCC00),
      Color(0xFF34C759), Color(0xFF5AC8FA), Color(0xFF007AFF),
      Color(0xFF5856D6), Color(0xFFFF2D55),
    ];
    return colors[hash.abs() % colors.length];
  }

  String _formatViews(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return '$count';
  }

  @override
  Widget build(BuildContext context) {
    final likes = List<String>.from(widget.shortData['likes'] ?? []);
    final isLiked = likes.contains(widget.currentUsername);
    final creator = widget.shortData['creator'] as String? ?? 'creator';
    final title = widget.shortData['title'] as String? ?? '';
    final commentCount = widget.shortData['commentCount'] ?? 0;
    final viewCount = widget.shortData['viewCount'] as int? ?? 0;

    return Stack(
      fit: StackFit.expand,
      children: [
        // ═══════════════════════════════════════════════════════
        // 1. NATIVE VIDEO PLAYER (BoxFit.cover)
        // ═══════════════════════════════════════════════════════
        Container(
          color: Colors.black,
          child: _isControllerInitialized && _controller != null
              ? SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover, // Perfectly fill vertical space
                    child: SizedBox(
                      width: _controller!.value.size.width,
                      height: _controller!.value.size.height,
                      child: VideoPlayer(_controller!),
                    ),
                  ),
                )
              : const Center(child: CircularProgressIndicator(color: Colors.white24)),
        ),

        // ═══════════════════════════════════════════════════════
        // 2. GRADIENT OVERLAYS
        // ═══════════════════════════════════════════════════════
        IgnorePointer(
          child: Column(children: [
            Container(
              height: 160,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black87, Colors.transparent],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            const Spacer(),
            Container(
              height: 240,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, Colors.black54, Colors.black87],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ]),
        ),

        // ═══════════════════════════════════════════════════════
        // 3. GESTURE LAYER
        // ═══════════════════════════════════════════════════════
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: _triggerDoubleTapLike,
            onTap: _toggleMute,
            onLongPressStart: (_) {
              _controller?.pause();
              setState(() => _showPauseIndicator = true);
              _discRotationController.stop();
            },
            onLongPressEnd: (_) {
              _controller?.play();
              setState(() => _showPauseIndicator = false);
              _discRotationController.repeat();
            },
            onHorizontalDragEnd: (details) {
              final v = details.primaryVelocity ?? 0;
              if (v < -500) _showCommentsBottomSheet();
              else if (v > 500) _showCreatorProfileSheet();
            },
            child: const SizedBox.expand(),
          ),
        ),

        // ═══════════════════════════════════════════════════════
        // 4. BOTTOM LEFT — Creator info strip
        // ═══════════════════════════════════════════════════════
        Positioned(
          left: 16,
          bottom: 28,
          right: 90,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: _avatarColor(creator),
                  child: Text(creator.isNotEmpty ? creator[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text('@$creator',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                      overflow: TextOverflow.ellipsis),
                ),
                if (widget.isFriend) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.verified_rounded, color: Color(0xFF0A84FF), size: 16),
                ],
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => setState(() => _isSubscribed = !_isSubscribed),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: _isSubscribed ? const Color(0xFF2C2C2E) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _isSubscribed ? 'Subscribed' : 'Subscribe',
                      style: TextStyle(color: _isSubscribed ? Colors.white70 : Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 14), maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Row(children: [
                if (viewCount > 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.visibility_rounded, color: Colors.white60, size: 12),
                      const SizedBox(width: 4),
                      Text('${_formatViews(viewCount)} views', style: const TextStyle(color: Colors.white60, fontSize: 11)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                ],
                const Icon(Icons.music_note_rounded, color: Colors.white60, size: 14),
                const SizedBox(width: 5),
                Expanded(
                  child: MarqueeText(
                    text: 'Original Sound - @$creator',
                    style: const TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ),
              ]),
            ],
          ),
        ),

        // ═══════════════════════════════════════════════════════
        // 5. RIGHT COLUMN — Action buttons
        // ═══════════════════════════════════════════════════════
        Positioned(
          right: 12,
          bottom: 28,
          child: Column(children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: _avatarColor(creator),
                  child: Text(creator.isNotEmpty ? creator[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                if (!_isSubscribed)
                  Positioned(
                    bottom: -4, left: 0, right: 0,
                    child: Center(
                      child: Container(
                        width: 20, height: 20,
                        decoration: BoxDecoration(color: widget.accentColor, shape: BoxShape.circle, border: Border.all(color: Colors.black, width: 2)),
                        child: const Icon(Icons.add, color: Colors.white, size: 12),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            _actionButton(
              icon: isLiked ? Icons.favorite : Icons.favorite_border_rounded,
              color: isLiked ? const Color(0xFFFF2D55) : Colors.white,
              label: likes.length.toString(),
              onTap: _toggleLike,
            ),
            const SizedBox(height: 18),
            _actionButton(
              icon: Icons.chat_bubble_outline_rounded,
              color: Colors.white,
              label: commentCount.toString(),
              onTap: _showCommentsBottomSheet,
            ),
            const SizedBox(height: 18),
            _actionButton(
              icon: widget.isBookmarked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              color: widget.isBookmarked ? const Color(0xFFFFCC00) : Colors.white,
              label: 'Save',
              onTap: _triggerBookmark,
            ),
            const SizedBox(height: 18),
            _actionButton(
              icon: Icons.send_rounded,
              color: Colors.white,
              label: 'Share',
              onTap: _shareShort,
            ),
            const SizedBox(height: 22),
            RotationTransition(
              turns: Tween(begin: 0.0, end: 1.0).animate(_discRotationController),
              child: Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 2.5),
                  gradient: const SweepGradient(colors: [Colors.black, Colors.grey, Colors.black, Colors.grey, Colors.black]),
                ),
                child: Center(
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: _avatarColor(creator),
                    child: Text(creator.isNotEmpty ? creator[0].toUpperCase() : '♫',
                        style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ),
          ]),
        ),

        // ═══════════════════════════════════════════════════════
        // 6. OVERLAYS (Watch time, Watched badge, Hearts, Pause, Mute)
        // ═══════════════════════════════════════════════════════
        if (widget.isActive && _watchSeconds > 0)
          Positioned(top: 120, left: 16, child: _buildWatchTimeRing()), // Adjusted padding top

        if (widget.isWatched && !widget.isActive)
          Positioned(
            bottom: 8, right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.visibility_rounded, color: Colors.white54, size: 10),
                SizedBox(width: 3),
                Text('Watched', style: TextStyle(color: Colors.white54, fontSize: 9)),
              ]),
            ),
          ),

        if (_heartParticles.isNotEmpty)
          AnimatedBuilder(
            animation: _heartParticleController,
            builder: (context, _) {
              final t = _heartParticleController.value;
              if (t >= 1.0) return const SizedBox.shrink();
              final size = MediaQuery.of(context).size;
              final cx = size.width / 2;
              final cy = size.height / 2;
              return IgnorePointer(
                child: Stack(
                  children: _heartParticles.map((p) {
                    final x = cx + p.velocityX * t;
                    final y = cy + p.velocityY * t;
                    final opacity = (1.0 - t * 1.4).clamp(0.0, 1.0);
                    final scale = p.baseScale * (1.0 - t * 0.4);
                    return Positioned(
                      left: x - 12, top: y - 12,
                      child: Opacity(
                        opacity: opacity,
                        child: Transform.scale(scale: scale, child: Icon(Icons.favorite, color: p.color, size: 24)),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),

        if (_showCenterHeart)
          IgnorePointer(
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.2),
                duration: const Duration(milliseconds: 300),
                builder: (context, scale, child) {
                  return Opacity(
                    opacity: scale > 1.0 ? (1.2 - scale) * 5.0 : 1.0,
                    child: Transform.scale(scale: scale, child: const Icon(Icons.favorite, color: Color(0xFFFF2D55), size: 110)),
                  );
                },
              ),
            ),
          ),

        if (_showMuteIndicator)
          IgnorePointer(
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 400),
                builder: (context, val, _) {
                  return Opacity(
                    opacity: 1.0 - val,
                    child: Transform.scale(
                      scale: 0.8 + (val * 0.4),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: Icon(widget.isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: Colors.white, size: 36),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

        if (_showPauseIndicator)
          IgnorePointer(
            child: Positioned.fill(
              child: Container(
                color: Colors.black26,
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(40),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 44),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

        if (_showBookmarkPop)
          IgnorePointer(
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 500),
                builder: (context, val, _) {
                  return Opacity(
                    opacity: (1.0 - val).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: 0.6 + (val * 0.6),
                      child: Icon(widget.isBookmarked ? Icons.bookmark_rounded : Icons.bookmark_remove_rounded,
                        color: widget.isBookmarked ? const Color(0xFFFFCC00) : Colors.white70, size: 80),
                    ),
                  );
                },
              ),
            ),
          ),

        // ═══════════════════════════════════════════════════════
        // 7. GLOWING PROGRESS BAR
        // ═══════════════════════════════════════════════════════
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: IgnorePointer(
            child: SizedBox(
              height: 3,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth * _progressFraction;
                  return Stack(children: [
                    Container(color: Colors.white.withValues(alpha: 0.1)),
                    Container(
                      width: w,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [Colors.white.withValues(alpha: 0.6), widget.accentColor]),
                        boxShadow: [BoxShadow(color: widget.accentColor.withValues(alpha: 0.5), blurRadius: 6)],
                      ),
                    ),
                  ]);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _actionButton({required IconData icon, required Color color, required String label, required VoidCallback onTap, double size = 28}) {
    return Column(children: [
      GestureDetector(onTap: onTap, child: Icon(icon, color: color, size: size)),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _buildWatchTimeRing() {
    final fraction = (_watchSeconds / 60.0).clamp(0.0, 1.0);
    final isFull = _watchSeconds >= 60;
    return SizedBox(
      width: 36, height: 36,
      child: Stack(alignment: Alignment.center, children: [
        CustomPaint(
          size: const Size(36, 36),
          painter: _WatchTimeRingPainter(fraction: fraction, color: isFull ? const Color(0xFF30D158) : widget.accentColor),
        ),
        Text(_watchSeconds < 60 ? '${_watchSeconds}s' : '1m', style: TextStyle(color: isFull ? const Color(0xFF30D158) : Colors.white70, fontSize: 9, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

class _WatchTimeRingPainter extends CustomPainter {
  final double fraction;
  final Color color;
  _WatchTimeRingPainter({required this.fraction, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    canvas.drawCircle(center, radius, Paint()..color = Colors.white.withValues(alpha: 0.1)..style = PaintingStyle.stroke..strokeWidth = 2.5);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, 2 * math.pi * fraction, false, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round);
  }
  @override
  bool shouldRepaint(covariant _WatchTimeRingPainter old) => old.fraction != fraction || old.color != color;
}

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const MarqueeText({super.key, required this.text, required this.style});
  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  late AnimationController _animationController;
  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _animationController = AnimationController(vsync: this, duration: const Duration(seconds: 8))..addListener(() {
      if (_scrollController.hasClients) {
        final max = _scrollController.position.maxScrollExtent;
        if (max > 0) _scrollController.jumpTo(_animationController.value * max);
      }
    })..repeat();
  }
  @override
  void dispose() {
    _scrollController.dispose();
    _animationController.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22, width: 150,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(children: [Text(widget.text, style: widget.style), const SizedBox(width: 40), Text(widget.text, style: widget.style)]),
      ),
    );
  }
}

class AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<ui.PointerDeviceKind> get dragDevices => {ui.PointerDeviceKind.touch, ui.PointerDeviceKind.mouse};
}
