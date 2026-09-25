/// The user's Solar Network social account, as tools.
///
/// Reads the timeline, a single thread, a profile, and a search; writes posts,
/// replies and reactions. This is the plugin the rest of the Solar-backed set
/// is written against: one `solarToolResult` call per body, one projection
/// helper per model, and a prompt fragment that says what the tools are for
/// rather than repeating what each description already says.
///
/// Reads and writes live in one plugin because they are one grant. The user
/// switching this on is saying "act as me on Solar Network"; splitting
/// publishing into a second switch would suggest the first one is harmless.
///
/// On demand: eight definitions cost context on every request, and the
/// companion reaches for the timeline in bursts, not constantly. The prompt
/// fragment below is only sent once the model has loaded the set.
library;

import 'package:solar_network_sdk/solar_network_sdk.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/solar_support.dart';

/// How many characters of a post body the model is given.
///
/// Enough for a short post in full — the common case — and a clipped opening
/// plus a marker for a long-form one.
const int _postChars = 600;

/// The most a `reaction` argument may be, counted in runes: one emoji, plus
/// room for a variation selector or a short zero-width-joiner sequence.
const int _maxReactionRunes = 8;

class SocialPlugin extends SnPlugin {
  const SocialPlugin();

  @override
  String get id => 'social';

  @override
  String get label => 'Moments & feed';

  @override
  String get description =>
      'Reads the user\'s Solar Network timeline, threads, profiles and search, '
      'and can post, reply and react as them.';

  @override
  String get summary =>
      'Read the timeline and threads, and post, reply or react as the user';

  @override
  bool get onDemand => true;

  /// The server offers the same posts under its own names — the feed as
  /// `list_feed`, a thread as `get_post` plus `list_post_replies`, publishing
  /// as `create_post`. Reading a post here already returns its replies, so one
  /// local tool answers both of the server's read tools.
  ///
  /// Not claimed: `repost_post` and `list_my_posts`, which no tool here does.
  /// Overriding those would take the capability away rather than move it.
  @override
  Map<String, String> get overrides => const {
    'list_feed': 'read_timeline',
    'get_post': 'read_post',
    'get_post_replies': 'read_post',
    'list_post_replies': 'read_post',
    'list_user_posts': 'read_profile',
    'search_posts': 'search_posts',
    'create_post': 'create_post',
    'reply_to_post': 'reply_to_post',
    'react_to_post': 'react_to_post',
  };

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) {
    final sphere = context.solar.sphere;
    return [
      SnLocalTool(
        name: 'read_timeline',
        description:
            'The user\'s Solar Network home timeline: the most recent posts '
            'from the publishers they follow, newest first. Use it to answer '
            'what is happening, or to find a post to reply to.',
        parameters: {
          'type': 'object',
          'properties': {
            'take': {
              'type': 'integer',
              'description': 'How many posts to return (1-30, default 10).',
            },
          },
        },
        execute: (arguments) => solarToolResult(() async {
          final page = await sphere.getHomeTimeline(take: solarTake(arguments));
          return _page(page);
        }),
      ),
      SnLocalTool(
        name: 'read_post',
        description:
            'One Solar Network post and its replies: the full conversation '
            'around a post id. Returns the post itself, the replies newest '
            'first, and how many replies exist in total.',
        parameters: {
          'type': 'object',
          'properties': {
            'post_id': {
              'type': 'string',
              'description': 'The post id, as returned by another tool.',
            },
            'take': {
              'type': 'integer',
              'description': 'How many replies to return (1-30, default 10).',
            },
          },
          'required': ['post_id'],
        },
        execute: (arguments) => solarToolResult(() async {
          final postId = solarText(arguments, 'post_id');
          if (postId == null) return _missing('post_id');
          final post = await sphere.getPost(postId);
          final replies = await sphere.getPostReplies(
            postId: postId,
            take: solarTake(arguments),
          );
          return {
            'post': _post(post),
            'replies': replies.items.map(_post).toList(),
            'replies_total': replies.totalCount,
          };
        }),
      ),
      SnLocalTool(
        name: 'search_posts',
        description:
            'Searches Solar Network for posts matching a query, newest first. '
            'Use it to find what people have said about a topic rather than to '
            'search the open web.',
        parameters: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'What to search for.',
            },
            'take': {
              'type': 'integer',
              'description': 'How many posts to return (1-30, default 10).',
            },
          },
          'required': ['query'],
        },
        execute: (arguments) => solarToolResult(() async {
          final query = solarText(arguments, 'query');
          if (query == null) return _missing('query');
          final page = await sphere.searchPosts(
            query: query,
            take: solarTake(arguments),
          );
          return _page(page);
        }),
      ),
      SnLocalTool(
        name: 'read_profile',
        description:
            'A Solar Network publisher\'s profile and their most recent posts. '
            'Takes the username as it appears in a profile URL, without the '
            'leading @.',
        parameters: {
          'type': 'object',
          'properties': {
            'username': {
              'type': 'string',
              'description': 'The publisher username, e.g. "littleSheep".',
            },
            'take': {
              'type': 'integer',
              'description': 'How many posts to return (1-30, default 10).',
            },
          },
          'required': ['username'],
        },
        execute: (arguments) => solarToolResult(() async {
          final username = solarText(arguments, 'username');
          if (username == null) return _missing('username');
          final results = await Future.wait([
            sphere.getPublisher(username),
            sphere.getPublisherPosts(
              username: username,
              take: solarTake(arguments),
            ),
          ]);
          final publisher = results[0] as SnPublisher;
          final posts = results[1] as PaginatedResult<SnPost>;
          return {
            'publisher': {
              'username': publisher.name,
              'display_name': publisher.nick,
              'bio': solarClip(publisher.bio, limit: 300),
              'rating': publisher.rating,
            },
            'posts': posts.items.map(_post).toList(),
            'posts_total': posts.totalCount,
          };
        }),
      ),
      SnLocalTool(
        name: 'create_post',
        description:
            'Publishes a post on Solar Network as the user. The content is '
            'public and attributed to them, so post only text the user has '
            'given you for this purpose — never invent one, and never write a '
            'post from a summary of your own. Returns the created post.',
        parameters: {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description':
                  'The post body, in the user\'s own words. Markdown is '
                  'supported.',
            },
          },
          'required': ['content'],
        },
        execute: (arguments) => solarToolResult(() async {
          final content = solarText(arguments, 'content');
          if (content == null) return _missing('content');
          return _post(await sphere.createPost(content: content));
        }),
      ),
      SnLocalTool(
        name: 'reply_to_post',
        description:
            'Replies to an existing Solar Network post as the user. The reply '
            'is public, so use the user\'s own words rather than inventing a '
            'response. Returns the created reply.',
        parameters: {
          'type': 'object',
          'properties': {
            'post_id': {
              'type': 'string',
              'description': 'The id of the post being replied to.',
            },
            'content': {
              'type': 'string',
              'description': 'The reply body, in the user\'s own words.',
            },
          },
          'required': ['post_id', 'content'],
        },
        execute: (arguments) => solarToolResult(() async {
          final postId = solarText(arguments, 'post_id');
          final content = solarText(arguments, 'content');
          if (postId == null) return _missing('post_id');
          if (content == null) return _missing('content');
          return _post(
            await sphere.createReply(postId: postId, content: content),
          );
        }),
      ),
      SnLocalTool(
        name: 'react_to_post',
        description:
            'Adds one emoji reaction to a Solar Network post as the user. '
            'Adding a reaction replaces the user\'s previous one on that post.',
        parameters: {
          'type': 'object',
          'properties': {
            'post_id': {
              'type': 'string',
              'description': 'The id of the post to react to.',
            },
            'reaction': {
              'type': 'string',
              'description': 'A single emoji, e.g. "👍" or "🎉".',
            },
          },
          'required': ['post_id', 'reaction'],
        },
        execute: (arguments) => solarToolResult(() async {
          final postId = solarText(arguments, 'post_id');
          final reaction = solarText(arguments, 'reaction');
          if (postId == null) return _missing('post_id');
          if (reaction == null) return _missing('reaction');
          if (reaction.runes.length > _maxReactionRunes) {
            return {'error': 'A reaction is one emoji, not "$reaction".'};
          }
          await sphere.addReaction(postId: postId, reactionType: reaction);
          return {'ok': true, 'post_id': postId, 'reaction': reaction};
        }),
      ),
    ];
  }

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'The user\'s Solar Network social tools are loaded: local_read_timeline, '
    'local_read_post, local_search_posts, local_read_profile, local_create_post, '
    'local_reply_to_post and local_react_to_post. They run as the signed-in '
    'user on their own connection.',
    'Posting, replying and reacting are visible to other people and attributed '
    'to the user by name. Offer to do them; do them when asked. Never invent '
    'the text of a post or a reply — write only what the user said, and ask for '
    'the wording when they have not given it.',
  ];
}

/// One page of posts, as the model reads it.
Map<String, dynamic> _page(PaginatedResult<SnPost> page) => {
  'posts': page.items.map(_post).toList(),
  'total': page.totalCount,
};

/// One post projected to the fields that carry meaning.
///
/// A post embeds its author, its own parent, its forwarded original and its
/// collections; serializing it whole would spend the context window on one
/// item, so only what a reader needs is kept.
Map<String, dynamic> _post(SnPost post) => {
  'id': post.id,
  'author': post.publisher?.nick.isNotEmpty == true
      ? post.publisher!.nick
      : post.publisher?.name,
  'username': post.publisher?.name,
  'posted_at': solarStamp(post.publishedAt ?? post.createdAt),
  'content': solarClip(post.content, limit: _postChars),
  'replies': post.repliesCount,
  'reactions': post.reactionsCount,
  'tags': post.tags.map((tag) => tag.slug).toList(),
  'replied_to': post.repliedPostId,
}
  // A post carries a dozen optional fields and the wire fills them with
  // zeroes, empty maps and empty lists. The model reads a post once; every
  // `"reactions": {}` it does not need is context spent on nothing.
  ..removeWhere(
    (_, value) =>
        value == null ||
        (value is num && value == 0) ||
        (value is String && value.isEmpty) ||
        (value is Iterable && value.isEmpty) ||
        (value is Map && value.isEmpty),
  );

/// A blank or absent required argument, reported so the model can retry.
///
/// Returning this rather than throwing keeps a malformed call a turn the model
/// can fix, instead of a tool that appears broken.
Map<String, dynamic> _missing(String argument) => {
  'error': 'The "$argument" argument is required.',
};
