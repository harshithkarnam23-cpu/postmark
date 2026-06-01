import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:ably_flutter/ably_flutter.dart' as ably;
import 'package:cloud_firestore/cloud_firestore.dart';

/// Singleton service that manages the Ably Realtime connection
/// and provides methods for chat channel operations.
class AblyService {
  // Singleton pattern
  AblyService._internal();
  static final AblyService _instance = AblyService._internal();
  static AblyService get instance => _instance;

  // Ably root key (development only — use Token Auth in production)
  static const String _apiKey =
      'PTE8mA.zr4p9A:yQ1ka2oZlHynj3JPsLLwjqJG0fFR3Pb2Ulwts2pl5k4';

  ably.Realtime? _realtime;
  String? _clientId;

  /// Whether the Ably client has been initialized
  /// On web, Ably is always disabled (no platform channel support).
  bool get isInitialized => !kIsWeb && _realtime != null;

  /// The current client ID (username)
  String? get clientId => _clientId;

  /// Initialize the Ably Realtime client with the current user's username
  Future<void> init(String clientId) async {
    // On web, skip Ably initialization (no platform channel support).
    // Firestore streams handle all real-time data delivery on web.
    if (kIsWeb) {
      _clientId = clientId;
      return;
    }

    if (_realtime != null && _clientId == clientId) return;

    // Close any existing connection first
    await dispose();

    _clientId = clientId;

    final clientOptions = ably.ClientOptions(
      key: _apiKey,
      clientId: clientId,
    );

    try {
      _realtime = ably.Realtime(options: clientOptions);
    } catch (e) {
      _realtime = null;
      debugPrint("Ably Realtime initialization failed: $e");
    }
  }

  /// Generate a deterministic channel name for a 1-on-1 chat.
  /// Sorts usernames alphabetically so both users always get the same channel.
  String getChatChannelName(String userA, String userB) {
    final sorted = [userA.toLowerCase(), userB.toLowerCase()]..sort();
    return 'chat:${sorted[0]}-${sorted[1]}';
  }

  /// Get (or create) an Ably channel by name
  ably.RealtimeChannel getChannel(String channelName) {
    if (_realtime == null) {
      throw StateError('AblyService not initialized. Call init() first.');
    }
    return _realtime!.channels.get(channelName);
  }

  /// Get the chat channel for a 1-on-1 conversation
  ably.RealtimeChannel getChatChannel(String userA, String userB) {
    final channelName = getChatChannelName(userA, userB);
    return getChannel(channelName);
  }

  /// Publish a chat message to a channel
  Future<void> publishMessage({
    required ably.RealtimeChannel channel,
    required String sender,
    required String text,
  }) async {
    await channel.publish(
      name: 'message',
      data: {
        'sender': sender,
        'text': text,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  /// Subscribe to incoming messages on a channel.
  /// Returns a Stream of message maps.
  Stream<Map<String, dynamic>> subscribeToMessages(
      ably.RealtimeChannel channel) {
    return channel.subscribe(name: 'message').map((ably.Message message) {
      final data = message.data;
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      return {
        'sender': message.clientId ?? 'unknown',
        'text': data?.toString() ?? '',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
    });
  }

  /// Save a message to Firestore for persistence
  Future<void> persistMessage({
    required String channelName,
    required String sender,
    required String text,
  }) async {
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(channelName)
        .collection('messages')
        .add({
      'sender': sender,
      'text': text,
      'timestamp': FieldValue.serverTimestamp(),
    });

    // Update the chat document with last message info
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(channelName)
        .set({
      'lastMessage': text,
      'lastSender': sender,
      'lastTimestamp': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Load persisted message history from Firestore
  Stream<QuerySnapshot> getMessageHistory(String channelName) {
    return FirebaseFirestore.instance
        .collection('chats')
        .doc(channelName)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots();
  }

  // ═══════════════════════════════════════════════════
  // FRIEND REQUEST SYSTEM
  // ═══════════════════════════════════════════════════

  /// Generate a deterministic channel name for friend request notifications
  String getRequestChannelName(String userA, String userB) {
    final sorted = [userA.toLowerCase(), userB.toLowerCase()]..sort();
    return 'request:${sorted[0]}-${sorted[1]}';
  }

  /// Get the Ably channel for friend request notifications between two users
  ably.RealtimeChannel getRequestChannel(String userA, String userB) {
    final channelName = getRequestChannelName(userA, userB);
    return getChannel(channelName);
  }

  /// Publish a friend request event via Ably for real-time notification
  Future<void> publishRequestEvent({
    required ably.RealtimeChannel channel,
    required String type, // "sent", "accepted", "declined", "cancelled"
    required String from,
    required String to,
    String? message,
  }) async {
    String title = '';
    String body = '';

    if (type == 'sent') {
      title = 'New Connection Request! 👥';
      body = '@$from wants to connect with you.';
    } else if (type == 'accepted') {
      title = 'Connection Request Accepted! 🤝';
      body = '@$from accepted your request.';
    } else if (type == 'declined') {
      title = 'Connection Request Declined ❌';
      body = '@$from declined your request.';
    } else if (type == 'cancelled') {
      title = 'Connection Request Cancelled 🚫';
      body = '@$from cancelled their request.';
    }

    final pushExtras = ably.MessageExtras({
      'push': {
        'notification': {
          'title': title,
          'body': body,
          'sound': 'default',
        },
        'data': {
          'type': type,
          'from': from,
          'to': to,
          'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
      }
    });

    await channel.publish(
      message: ably.Message(
        name: 'request_event',
        data: {
          'type': type,
          'from': from,
          'to': to,
          'message': message ?? '',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        },
        extras: pushExtras,
      ),
    );
  }

  /// Subscribe to friend request events on a channel
  Stream<Map<String, dynamic>> subscribeToRequestEvents(
      ably.RealtimeChannel channel) {
    return channel.subscribe(name: 'request_event').map((ably.Message message) {
      final data = message.data;
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      return {'type': 'unknown'};
    });
  }

  /// Helper to get a sorted relationship pair key
  String _getSortedPairKey(String userA, String userB) {
    final sorted = [userA.toLowerCase(), userB.toLowerCase()]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  /// Send a friend request — writes to Firestore + Realtime Database
  Future<void> sendFriendRequest({
    required String from,
    required String to,
  }) async {
    final message = "Hey $to, I'd love to connect with you on PostMark! 🚀";

    // 1. Create the friend request document in Firestore (segregated & persistent)
    final docRef = await FirebaseFirestore.instance.collection('friend_requests').add({
      'from': from,
      'to': to,
      'status': 'pending',
      'message': message,
      'responseMessage': null,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    final requestId = docRef.id;
    

    // 2. Write to Firestore Relationships collection
    final key = _getSortedPairKey(from, to);
    await FirebaseFirestore.instance.collection('relationships').doc(key).set({
      'status': 'pending',
      'from': from,
      'to': to,
      'message': message,
      'responseMessage': null,
      'requestId': requestId,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // 3. Log activity for both users in Firestore
    await _logActivity(
      user: from,
      type: 'sent',
      otherUser: to,
      message: message,
    );
    await _logActivity(
      user: to,
      type: 'received',
      otherUser: from,
      message: message,
    );
  }

  /// Accept a friend request — writes to Firestore + Realtime Database
  Future<void> acceptFriendRequest({
    required String requestId,
    required String from,
    required String to,
    required String acceptedBy,
  }) async {
    final responseMessage =
        "Hey $from, I'm $acceptedBy 👋 Glad we connected!";

    // 1. Update Firestore request status
    await FirebaseFirestore.instance
        .collection('friend_requests')
        .doc(requestId)
        .update({
      'status': 'accepted',
      'responseMessage': responseMessage,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // Create Firestore friendship record
    final sorted = [from.toLowerCase(), to.toLowerCase()]..sort();
    await FirebaseFirestore.instance.collection('friends').add({
      'users': sorted,
      'connectedAt': FieldValue.serverTimestamp(),
    });

    // 2. Update Firestore Relationships collection
    final key = _getSortedPairKey(from, to);
    
    // Retrieve the original request message from Firestore if possible
    final relSnap = await FirebaseFirestore.instance.collection('relationships').doc(key).get();
    String originalMsg = "Hey $to, I'd love to connect with you on PostMark! 🚀";
    if (relSnap.exists) {
      final data = relSnap.data();
      originalMsg = data?['message'] as String? ?? originalMsg;
    }

    await FirebaseFirestore.instance.collection('relationships').doc(key).set({
      'status': 'friends',
      'from': from,
      'to': to,
      'message': originalMsg,
      'responseMessage': responseMessage,
      'requestId': requestId,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // 3. Log activity for both users in Firestore
    await _logActivity(
      user: acceptedBy,
      type: 'accepted',
      otherUser: from,
      message: responseMessage,
    );
    await _logActivity(
      user: from,
      type: 'accepted',
      otherUser: acceptedBy,
      message: responseMessage,
    );
  }

  /// Decline a friend request
  Future<void> declineFriendRequest({
    required String requestId,
    required String declinedBy,
    required String otherUser,
  }) async {
    // 1. Update status in Firestore
    await FirebaseFirestore.instance
        .collection('friend_requests')
        .doc(requestId)
        .update({
      'status': 'declined',
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // 2. Update status in Firestore
    final key = _getSortedPairKey(declinedBy, otherUser);
    await FirebaseFirestore.instance.collection('relationships').doc(key).set({
      'status': 'none',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // 3. Log activity in Firestore
    await _logActivity(
      user: declinedBy,
      type: 'declined',
      otherUser: otherUser,
    );
    await _logActivity(
      user: otherUser,
      type: 'declined',
      otherUser: declinedBy,
    );
  }

  /// Cancel a friend request
  Future<void> cancelFriendRequest({
    required String requestId,
    required String cancelledBy,
    required String otherUser,
  }) async {
    // 1. Update status in Firestore
    await FirebaseFirestore.instance
        .collection('friend_requests')
        .doc(requestId)
        .update({
      'status': 'cancelled',
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // 2. Update status in Firestore
    final key = _getSortedPairKey(cancelledBy, otherUser);
    await FirebaseFirestore.instance.collection('relationships').doc(key).set({
      'status': 'none',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // 3. Log activity in Firestore
    await _logActivity(
      user: cancelledBy,
      type: 'cancelled',
      otherUser: otherUser,
    );
    await _logActivity(
      user: otherUser,
      type: 'cancelled',
      otherUser: cancelledBy,
    );
  }

  /// Streams relationship data from RTDB.
  Stream<DocumentSnapshot> streamRelationship(String userA, String userB) {
    final key = _getSortedPairKey(userA, userB);
    return FirebaseFirestore.instance.collection('relationships').doc(key).snapshots();
  }

  /// Streams received pending requests for a user from Realtime Database
  Stream<QuerySnapshot> getReceivedRequestsStream(String username) {
    return FirebaseFirestore.instance
        .collection('friend_requests')
        .where('to', isEqualTo: username)
        .snapshots();
  }

  /// Streams sent pending requests for a user from Realtime Database
  Stream<QuerySnapshot> getSentRequestsStream(String username) {
    return FirebaseFirestore.instance
        .collection('friend_requests')
        .where('from', isEqualTo: username)
        .snapshots();
  }

  /// Check if two users are already friends
  Future<bool> areFriends(String userA, String userB) async {
    final sorted = [userA.toLowerCase(), userB.toLowerCase()]..sort();
    final snapshot = await FirebaseFirestore.instance
        .collection('friends')
        .where('users', isEqualTo: sorted)
        .limit(1)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  /// Get active friend request between two users (pending only)
  Future<QuerySnapshot> getActiveRequest(String userA, String userB) async {
    // Check both directions
    final sentByA = await FirebaseFirestore.instance
        .collection('friend_requests')
        .where('from', isEqualTo: userA)
        .where('to', isEqualTo: userB)
        .where('status', isEqualTo: 'pending')
        .limit(1)
        .get();

    if (sentByA.docs.isNotEmpty) return sentByA;

    return await FirebaseFirestore.instance
        .collection('friend_requests')
        .where('from', isEqualTo: userB)
        .where('to', isEqualTo: userA)
        .where('status', isEqualTo: 'pending')
        .limit(1)
        .get();
  }

  /// Get the accepted request between two users (for message display)
  Future<QuerySnapshot> getAcceptedRequest(String userA, String userB) async {
    final sentByA = await FirebaseFirestore.instance
        .collection('friend_requests')
        .where('from', isEqualTo: userA)
        .where('to', isEqualTo: userB)
        .where('status', isEqualTo: 'accepted')
        .orderBy('updatedAt', descending: true)
        .limit(1)
        .get();

    if (sentByA.docs.isNotEmpty) return sentByA;

    return await FirebaseFirestore.instance
        .collection('friend_requests')
        .where('from', isEqualTo: userB)
        .where('to', isEqualTo: userA)
        .where('status', isEqualTo: 'accepted')
        .orderBy('updatedAt', descending: true)
        .limit(1)
        .get();
  }

  /// Get received pending requests for a user
  Stream<QuerySnapshot> getReceivedRequests(String username) {
    return FirebaseFirestore.instance
        .collection('friend_requests')
        .where('to', isEqualTo: username)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  /// Get sent pending requests by a user
  Stream<QuerySnapshot> getSentRequests(String username) {
    return FirebaseFirestore.instance
        .collection('friend_requests')
        .where('from', isEqualTo: username)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  /// Get activity feed for a user
  Stream<QuerySnapshot> getActivityFeed(String username) {
    return FirebaseFirestore.instance
        .collection('request_activity')
        .where('user', isEqualTo: username)
        .snapshots();
  }

  /// Internal: Log an activity event for a user
  Future<void> _logActivity({
    required String user,
    required String type,
    required String otherUser,
    String? message,
  }) async {
    await FirebaseFirestore.instance.collection('request_activity').add({
      'user': user,
      'type': type,
      'otherUser': otherUser,
      'message': message,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  /// Remove a friend — dissolves the friendship in Firestore.
  /// Sets the relationship status to 'none', deletes the friends record,
  /// and logs the dissolution activity for both users.
  Future<void> removeFriend({
    required String currentUsername,
    required String targetUsername,
  }) async {
    // 1. Update relationship status to 'none'
    final key = _getSortedPairKey(currentUsername, targetUsername);
    await FirebaseFirestore.instance.collection('relationships').doc(key).set({
      'status': 'none',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // 2. Delete friendship document from friends collection
    final sorted = [currentUsername.toLowerCase(), targetUsername.toLowerCase()]..sort();
    final friendSnap = await FirebaseFirestore.instance
        .collection('friends')
        .where('users', isEqualTo: sorted)
        .get();
    for (var doc in friendSnap.docs) {
      await doc.reference.delete();
    }

    // 3. Log dissolution activity for both users
    await _logActivity(
      user: currentUsername,
      type: 'removed',
      otherUser: targetUsername,
      message: 'Removed $targetUsername as a friend.',
    );
    await _logActivity(
      user: targetUsername,
      type: 'removed',
      otherUser: currentUsername,
      message: '$currentUsername removed you as a friend.',
    );
  }

  /// Close the Ably connection and clean up
  Future<void> dispose() async {
    if (!kIsWeb) {
      _realtime?.close();
    }
    _realtime = null;
    _clientId = null;
  }
}
