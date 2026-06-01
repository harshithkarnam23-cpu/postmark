import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'ably_service.dart';

/// Full-screen Friend Request Page — shows the relationship between
/// the current user and the target user with action buttons.
///
/// 4 States:
///   1. Not Connected → "Send Friend Request"
///   2. Request Pending (I sent) → "Cancel Request"
///   3. Request Received (they sent) → "Accept" / "Decline"
///   4. Already Friends → "Go Back"
class FriendRequestPage extends StatefulWidget {
  final String currentUsername;
  final String targetUsername;
  final Color avatarColor;
  final String profilePictureUrl;
  final Color accentColor;

  const FriendRequestPage({
    super.key,
    required this.currentUsername,
    required this.targetUsername,
    required this.avatarColor,
    required this.profilePictureUrl,
    required this.accentColor,
  });

  @override
  State<FriendRequestPage> createState() => _FriendRequestPageState();
}

enum _RequestState { loading, notConnected, pendingSent, pendingReceived, friends }

class _FriendRequestPageState extends State<FriendRequestPage> {
  String? _requestId;
  String? _requestFrom;
  String? _loadingAction;

  @override
  void initState() {
    super.initState();
    // Lazy population from firestore is obsolete, we use firestore natively.
  }

  Future<void> _sendRequest() async {
    if (_loadingAction != null) return;
    setState(() => _loadingAction = 'send');

    try {
      await AblyService.instance.sendFriendRequest(
        from: widget.currentUsername,
        to: widget.targetUsername,
      );

      // Publish Ably event for real-time notification
      if (AblyService.instance.isInitialized) {
        final channel = AblyService.instance.getRequestChannel(
          widget.currentUsername,
          widget.targetUsername,
        );
        await AblyService.instance.publishRequestEvent(
          channel: channel,
          type: 'sent',
          from: widget.currentUsername,
          to: widget.targetUsername,
        );
      }
    } finally {
      if (mounted) setState(() => _loadingAction = null);
    }
  }

  Future<void> _cancelRequest() async {
    if (_loadingAction != null || _requestId == null) return;
    setState(() => _loadingAction = 'cancel');

    try {
      await AblyService.instance.cancelFriendRequest(
        requestId: _requestId!,
        cancelledBy: widget.currentUsername,
        otherUser: widget.targetUsername,
      );

      if (AblyService.instance.isInitialized) {
        final channel = AblyService.instance.getRequestChannel(
          widget.currentUsername,
          widget.targetUsername,
        );
        await AblyService.instance.publishRequestEvent(
          channel: channel,
          type: 'cancelled',
          from: widget.currentUsername,
          to: widget.targetUsername,
        );
      }
    } finally {
      if (mounted) setState(() => _loadingAction = null);
    }
  }

  Future<void> _acceptRequest() async {
    if (_loadingAction != null || _requestId == null) return;
    setState(() => _loadingAction = 'accept');

    try {
      await AblyService.instance.acceptFriendRequest(
        requestId: _requestId!,
        from: _requestFrom ?? widget.targetUsername,
        to: widget.currentUsername,
        acceptedBy: widget.currentUsername,
      );

      if (AblyService.instance.isInitialized) {
        final channel = AblyService.instance.getRequestChannel(
          widget.currentUsername,
          widget.targetUsername,
        );
        await AblyService.instance.publishRequestEvent(
          channel: channel,
          type: 'accepted',
          from: widget.currentUsername,
          to: widget.targetUsername,
        );
      }
    } finally {
      if (mounted) setState(() => _loadingAction = null);
    }
  }

  Future<void> _declineRequest() async {
    if (_loadingAction != null || _requestId == null) return;
    setState(() => _loadingAction = 'decline');

    try {
      await AblyService.instance.declineFriendRequest(
        requestId: _requestId!,
        declinedBy: widget.currentUsername,
        otherUser: widget.targetUsername,
      );

      if (AblyService.instance.isInitialized) {
        final channel = AblyService.instance.getRequestChannel(
          widget.currentUsername,
          widget.targetUsername,
        );
        await AblyService.instance.publishRequestEvent(
          channel: channel,
          type: 'declined',
          from: widget.currentUsername,
          to: widget.targetUsername,
        );
      }
    } finally {
      if (mounted) setState(() => _loadingAction = null);
    }
  }

  Future<void> _removeFriend() async {
    if (_loadingAction != null) return;
    setState(() => _loadingAction = 'remove');

    try {
      await AblyService.instance.removeFriend(
        currentUsername: widget.currentUsername,
        targetUsername: widget.targetUsername,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed @${widget.targetUsername} as a friend'),
          backgroundColor: const Color(0xFF1C1C1E),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(milliseconds: 1500),
        ),
      );
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _loadingAction = null);
    }
  }

  void _showRemoveFriendConfirmation() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Remove Friend',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(
          'Are you sure you want to remove @${widget.targetUsername} as a friend? You will need to send a new request to reconnect.',
          style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _removeFriend();
            },
            child: const Text('Remove', style: TextStyle(color: Color(0xFFFF453A), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: AblyService.instance.streamRelationship(
        widget.currentUsername,
        widget.targetUsername,
      ),
      builder: (context, snapshot) {
        // Determine UI state from the stream data
        _RequestState uiState = _RequestState.loading;
        String? message;
        String? responseMessage;
        String? from;

        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          final status = data?['status'] as String? ?? 'none';
          from = data?['from'] as String?;
          message = data?['message'] as String?;
          responseMessage = data?['responseMessage'] as String?;
          final requestId = data?['requestId'] as String?;

          if (status == 'friends') {
            uiState = _RequestState.friends;
          } else if (status == 'pending') {
            uiState = from == widget.currentUsername
                ? _RequestState.pendingSent
                : _RequestState.pendingReceived;
          } else {
            uiState = _RequestState.notConnected;
          }

          _requestId = requestId;
          _requestFrom = from;
        } else if (snapshot.hasData && !snapshot.data!.exists) {
          uiState = _RequestState.notConnected;
        }

        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: const Color(0xFF111111),
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_new,
                  color: widget.accentColor, size: 20),
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
                          style:
                              const TextStyle(color: Colors.white, fontSize: 12),
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
              if (uiState == _RequestState.friends)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  color: const Color(0xFF1C1C1E),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: Color(0xFF3A3A3C), width: 0.5),
                  ),
                  onSelected: (value) {
                    if (value == 'remove_friend') {
                      _showRemoveFriendConfirmation();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem<String>(
                      value: 'remove_friend',
                      child: Row(
                        children: [
                          Icon(Icons.person_remove_alt_1_rounded, color: Color(0xFFFF453A), size: 20),
                          SizedBox(width: 12),
                          Text('Remove Friend', style: TextStyle(color: Color(0xFFFF453A))),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
          body: _buildBody(uiState, snapshot, message, responseMessage, from),
        );
      },
    );
  }

  Widget _buildBody(_RequestState uiState, AsyncSnapshot<DocumentSnapshot> snapshot, String? message, String? responseMessage, String? from) {
    if (snapshot.hasError) {
      return Center(
        child: Text(
          'Error loading relationship: ${snapshot.error}',
          style: const TextStyle(color: Colors.white),
        ),
      );
    }

    if (!snapshot.hasData) {
      return Center(
        child: CircularProgressIndicator(color: widget.accentColor),
      );
    }

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 32),
              child: _buildContent(uiState, message, responseMessage, from),
            ),
          ),
          _buildBottomAction(uiState),
        ],
      ),
    );
  }

  Widget _buildContent(
    _RequestState state,
    String? message,
    String? responseMsg,
    String? reqFrom,
  ) {
    switch (state) {
      case _RequestState.loading:
        return const SizedBox.shrink();

      case _RequestState.notConnected:
        return _buildNotConnected();

      case _RequestState.pendingSent:
        return _buildPendingSent(message);

      case _RequestState.pendingReceived:
        return _buildPendingReceived(message);

      case _RequestState.friends:
        return _buildAlreadyFriends(message, responseMsg, reqFrom);
    }
  }

  // ═══════════════════════════════════════════════════
  // STATE 1: Not Connected
  // ═══════════════════════════════════════════════════
  Widget _buildNotConnected() {
    return Column(
      children: [
        const SizedBox(height: 40),
        _buildLargeAvatar(),
        const SizedBox(height: 24),
        Text(
          'Connect with ${widget.targetUsername}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'Start a new conversation today',
          style: TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 15,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════
  // STATE 2: Pending (I sent)
  // ═══════════════════════════════════════════════════
  Widget _buildPendingSent(String? message) {
    return Column(
      children: [
        const SizedBox(height: 40),
        _buildLargeAvatar(),
        const SizedBox(height: 16),
        const Icon(Icons.hourglass_top_rounded,
            color: Color(0xFF0A84FF), size: 36),
        const SizedBox(height: 12),
        const Text(
          'Request Pending',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
          ),
          textAlign: TextAlign.center,
        ),
        if (message != null) ...[
          const SizedBox(height: 32),
          _buildMessageBubble(
            message: message,
            isMe: true,
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════
  // STATE 3: Pending (they sent to me)
  // ═══════════════════════════════════════════════════
  Widget _buildPendingReceived(String? message) {
    return Column(
      children: [
        const SizedBox(height: 40),
        _buildLargeAvatar(),
        const SizedBox(height: 20),
        Text(
          '${widget.targetUsername} sent you a request:',
          style: const TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 16,
          ),
          textAlign: TextAlign.center,
        ),
        if (message != null) ...[
          const SizedBox(height: 24),
          _buildMessageBubble(
            message: message,
            isMe: false,
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════
  // STATE 4: Already Friends
  // ═══════════════════════════════════════════════════
  Widget _buildAlreadyFriends(String? message, String? responseMsg, String? reqFrom) {
    final bool requestWasFromMe = reqFrom == widget.currentUsername;

    return Column(
      children: [
        const SizedBox(height: 40),
        _buildLargeAvatar(),
        const SizedBox(height: 16),
        const Icon(Icons.check_circle, color: Color(0xFF30D158), size: 36),
        const SizedBox(height: 12),
        const Text(
          'Already Friends 🤝',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        if (message != null)
          _buildMessageBubble(
            message: message,
            isMe: requestWasFromMe,
          ),
        if (responseMsg != null) ...[
          const SizedBox(height: 12),
          _buildMessageBubble(
            message: responseMsg,
            isMe: !requestWasFromMe,
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════
  // SHARED WIDGETS & UI COMPONENTS
  // ═══════════════════════════════════════════════════

  Widget _buildLargeAvatar() {
    return CircleAvatar(
      radius: 56,
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
                fontSize: 40,
              ),
            )
          : null,
    );
  }

  /// Extremely sleek and professional chat bubbles matching real chat design
  Widget _buildMessageBubble({
    required String message,
    required bool isMe,
  }) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isMe ? widget.accentColor : const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            height: 1.3,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction(_RequestState state) {
    switch (state) {
      case _RequestState.loading:
        return const SizedBox(height: 80);

      case _RequestState.notConnected:
        return _buildActionBar(
          children: [
            Expanded(
              child: _buildActionButton(
                label: 'Send Friend Request',
                color: widget.accentColor,
                textColor: Colors.white,
                onPressed: _sendRequest,
                actionKey: 'send',
              ),
            ),
          ],
        );

      case _RequestState.pendingSent:
        return _buildActionBar(
          children: [
            Expanded(
              child: _buildActionButton(
                label: 'Cancel Request',
                color: Colors.transparent,
                textColor: const Color(0xFFFF453A),
                borderColor: const Color(0xFFFF453A),
                onPressed: _cancelRequest,
                actionKey: 'cancel',
              ),
            ),
          ],
        );

      case _RequestState.pendingReceived:
        return _buildActionBar(
          children: [
            Expanded(
              child: _buildActionButton(
                label: 'Accept',
                color: widget.accentColor,
                textColor: Colors.white,
                onPressed: _acceptRequest,
                actionKey: 'accept',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionButton(
                label: 'Decline',
                color: Colors.transparent,
                textColor: const Color(0xFFFF453A),
                borderColor: const Color(0xFFFF453A),
                onPressed: _declineRequest,
                actionKey: 'decline',
              ),
            ),
          ],
        );

      case _RequestState.friends:
        return _buildActionBar(
          children: [
            Expanded(
              child: _buildActionButton(
                label: 'Go Back',
                color: Colors.transparent,
                textColor: Colors.white,
                borderColor: const Color(0xFF48484A),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildActionBar({required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      color: const Color(0xFF111111),
      child: Row(children: children),
    );
  }

  Widget _buildActionButton({
    required String label,
    required Color color,
    required Color textColor,
    Color? borderColor,
    required VoidCallback onPressed,
    String? actionKey,
  }) {
    final bool isLoading = _loadingAction != null && _loadingAction == actionKey;
    final bool isDisabled = _loadingAction != null;

    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: isDisabled ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          disabledBackgroundColor: color == Colors.transparent
              ? Colors.transparent
              : color.withAlpha(100),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
            side: borderColor != null
                ? BorderSide(color: borderColor, width: 1.5)
                : BorderSide.none,
          ),
        ),
        child: isLoading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: textColor,
                ),
              )
            : Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 16,
                ),
              ),
      ),
    );
  }
}
