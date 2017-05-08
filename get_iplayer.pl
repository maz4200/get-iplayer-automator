#!/usr/bin/env perl
#
# get_iplayer - Lists and records BBC iPlayer TV and radio programmes
#
#    Copyright (C) 2008-2010 Phil Lewis
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Author: Phil Lewis
# Email: iplayer2 (at sign) linuxcentre.net
# Web: https://github.com/get-iplayer/get_iplayer/wiki
# License: GPLv3 (see LICENSE.txt)
#
#
package main;
use lib '/usr/local/Cellar/get_iplayer/3.01.0/libexec/perl5/lib';
my $version = 3.01;
my $version_text = "3.01-homebrew.0";
$version_text = sprintf("v%.2f", $version) unless $version_text;
#
# Help:
#	./get_iplayer --help | --longhelp
#
# Changelog:
# 	https://github.com/get-iplayer/get_iplayer/wiki/releasenotes
#
# Usage and Examples:
# 	https://github.com/get-iplayer/get_iplayer/wiki/documentation
#
# Todo:
# ** all global vars into a class???
# ** Cut down 'use' clauses in each class
# * Add PVR search src to recording history
# * Fix unicode / wide chars in rdf
#
# Known Issues:
# * CAVEAT: The filenames and modes in the history are comma-separated if there was a multimode download. For now it just uses the first one.
#
use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use File::Spec;
use Getopt::Long;
use HTML::Entities;
use HTTP::Cookies;
use HTTP::Headers;
use IO::Seekable;
use IO::Socket;
use LWP::ConnCache;
use LWP::UserAgent;
use POSIX qw(mkfifo strftime);
use POSIX qw(:termios_h);
use strict;
#use warnings;
use Time::Local;
use Unicode::Normalize;
use URI;
use open qw(:utf8);
use Encode qw(:DEFAULT :fallback_all);
use PerlIO::encoding;
$PerlIO::encoding::fallback = XMLCREF;
use constant FB_EMPTY => sub { '' };

my %SIGORIG;
# Save default SIG actions
$SIGORIG{$_} = $SIG{$_} for keys %SIG;
STDOUT->autoflush(1);
STDERR->autoflush(1);
# Save proxy env var
my $ENV_HTTP_PROXY = $ENV{HTTP_PROXY} || $ENV{http_proxy};

# Hash of all prog types => Programme class
# Add an entry here if another Programme class is added
my %prog_types = (
	tv		=> 'Programme::tv',
	radio		=> 'Programme::radio'
);


# Programme instance data
# $prog{$pid} = Programme->new (
#	'index'		=> <index number>,
#	'name'		=> <programme short name>,
#	'episode'	=> <Episode info>,
#	'desc'		=> <Long Description>,
#	'available'	=> <Date/Time made available or remaining>,
#	'duration'	=> <duration in free text form>
#	'versions'	=> <comma separated list of versions, e.g default, signed, audiodescribed>
#	'thumbnail'	=> <programme thumbnail url>
#	'channel	=> <channel>
#	'categories'	=> <Comma separated list of categories>
# 	'type'		=> <prog_type>
#	'timeadded'	=> <timestamp when programme was added to cache>
#	'version'	=> <selected version e.g default, signed, audiodescribed, etc - only set before recording>
#	'filename'	=> <Path and Filename of saved file - set only while recording>
#	'dir'		=> <Filename Directory of saved file - set only while recording>
#	'fileprefix'	=> <Filename Prefix of saved file - set only while recording>
#	'ext'		=> <Filename Extension of saved file - set only while recording>
#);


# Define general 'option names' => ( <help mask>, <option help section>, <option cmdline format>, <usage text>, <option help> )
# <help mask>: 0 for normal help, 1 for advanced help, 2 for basic help
# If you want the option to be hidden then don't specify <option help section>, use ''
# Entries with keys starting with '_' are not parsed only displayed as help and in man pages.
my $opt_format = {
	# Recording
	attempts	=> [ 1, "attempts=n", 'Recording', '--attempts <number>', "Number of attempts to make or resume a failed connection.  --attempts is applied per-stream, per-mode.  Many modes have two or more streams available."],
	excludesupplier	=> [ 1, "excludesupplier|exclude-supplier=s", 'Recording', '--exclude-supplier <supplier>,<supplier>,...', "Comma-separated list of media stream suppliers to skip.  Possible values: akamai,limelight"],
	force		=> [ 1, "force|force-download!", 'Recording', '--force', "Ignore programme history (unsets --hide option also).  Forces a script update if used with -u"],
	fps50		=> [ 1, "fps50", 'Recording', '--fps50', "Prefer 50 fps streams for TV programmes (not available for all video sizes)."],
	get		=> [ 2, "get|record|g!", 'Recording', '--get, -g', "Start recording matching programmes.  Search terms required unless --pid specified.  Use  --search=.* to force download of all available programmes."],
	includesupplier	=> [ 1, "includesupplier|include-supplier=s", 'Recording', '--include-supplier <supplier>,<supplier>,...', "Comma-separated list of media stream suppliers to use if not included by default.  Possible values: akamai,limelight,bidi"],
	hash		=> [ 1, "hash!", 'Recording', '--hash', "Show recording progress as hashes"],
	logprogress		=> [ 1, "log-progress|logprogress!", 'Recording', '--log-progress', "Force HLS/DASH download progress display to be captured when screen output is redirected to file.  Progress display is normally omitted unless writing to terminal."],
	metadataonly	=> [ 1, "metadataonly|metadata-only!", 'Recording', '--metadata-only', "Create specified metadata info file without any recording or streaming (can also be used with thumbnail option)."],
	modes		=> [ 0, "modes=s", 'Recording', '--modes <mode>,<mode>,...', "Recording modes.  See --tvmode and --radiomode (with --long-help) for available modes and defaults.  Shortcuts: tvworst,tvworse,tvgood,tvvgood,tvbetter,tvbest,radioworst,radioworse,radiogood,radiovgood,radiobetter,radiobest (default=default for programme type)."],
	noproxy	=> [ 1, "noproxy|no-proxy!", 'Recording', '--no-proxy', "Ignore --proxy setting in preferences"],
	overwrite	=> [ 1, "overwrite|over-write!", 'Recording', '--overwrite', "Overwrite recordings if they already exist"],
	partialproxy	=> [ 1, "partial-proxy!", 'Recording', '--partial-proxy', "Only uses web proxy where absolutely required (try this extra option if your proxy fails).  If specified, value of http_proxy environment variable (if any) in parent process is retained and passed to child processes."],
	_url		=> [ 2, "", 'Recording', '--url <url>,<url>,...', "Record the embedded media in the specified iPlayer episode URLs.  Use with --type."],
	pid		=> [ 2, "pid|url=s@", 'Recording', '--pid <pid>,<pid>,...', "Record arbitrary PIDs that do not necessarily appear in the index."],
	pidrecursive	=> [ 1, "pidrecursive|pid-recursive!", 'Recording', '--pid-recursive', "Record all related episodes if value of --pid is a series or brand PID.  Requires --pid."],
	proxy		=> [ 0, "proxy|p=s", 'Recording', '--proxy, -p <url>', "Web proxy URL e.g. 'http://USERNAME:PASSWORD\@SERVER:PORT' or 'http://SERVER:PORT'.  Sets http_proxy environment variable for child processes (e.g., ffmpeg) unless --partial-proxy is specified."],
	raw		=> [ 0, "raw!", 'Recording', '--raw', "Don't remux or change the recording in any way.  Saves output file in native container format (HLS->MPEG-TS, DASH->MP4)"],
	start		=> [ 1, "start=s", 'Recording', '--start <secs|hh:mm:ss>', "Recording/streaming start offset (actual start may be several seconds earlier for HLS and DASH streams)"],
	stop		=> [ 1, "stop=s", 'Recording', '--stop <secs|hh:mm:ss>', "Recording/streaming stop offset (actual stop may be several seconds later for HLS and DASH streams)"],
	suboffset	=> [ 1, "suboffset=n", 'Recording', '--suboffset <offset>', "Offset the subtitle timestamps by the specified number of milliseconds"],
	subtitles	=> [ 2, "subtitles|subs!", 'Recording', '--subtitles', "Download subtitles into srt/SubRip format if available and supported"],
	subsfmt		=> [ 1, "subsfmt=s", 'Deprecated', '--subsfmt <format>', "Subtitles format.  One of: default, compact.  Default: 'default'"],
	subsonly	=> [ 1, "subtitlesonly|subsonly|subtitles-only|subs-only!", 'Recording', '--subtitles-only', "Only download the subtitles, not the programme"],
	subsmono	=> [ 1, "subsmono|subs-mono!", 'Recording', '--subs-mono', "Create monochrome titles, with leading hyphen used to denote change of speaker."],
	subsraw		=> [ 1, "subsraw!", 'Recording', '--subsraw', "Additionally save the raw subtitles file"],
	subsrequired		=> [ 1, "subsrequired|subs-required|subtitles-required!", 'Recording', '--subtitles-required', "Do not download TV programme if subtitles are not available."],
	tagonly		=> [ 1, "tagonly|tag-only!", 'Recording', '--tag-only', "Only update the programme metadata tag and not download the programme (can also be used with --history)"],
	tagonlyfilename		=> [ 1, "tagonlyfilename|tag-only-filename=s", 'Recording', '--tag-only-filename <filename>', "Add metadata tags to specified file (ignored unless used with --tag-only)"],
	test		=> [ 1, "test|t!", 'Recording', '--test, -t', "Test only - no recording (will show programme type)"],
	thumb		=> [ 1, "thumb|thumbnail!", 'Recording', '--thumb', "Download Thumbnail image if available"],
	thumbonly	=> [ 1, "thumbonly|thumbnailonly|thumbnail-only|thumb-only!", 'Recording', '--thumbnail-only', "Only Download Thumbnail image if available, not the programme"],
	versionlist	=> [ 1, "versionlist|versions|version-list=s", 'Recording', '--versions <versions>', "Version of programme to record.  List is processed from left to right and first version found is downloaded.  Example: '--versions=audiodescribed,default' will prefer audiodescribed programmes if available."],

	# Search
	availablesince		=> [ 0, "availablesince|available-since=n", 'Search', '--available-since <hours>', "Limit search to programmes that have become available in the last <hours> hours"],
	before		=> [ 1, "before=n", 'Search', '--before <hours>', "Limit search to programmes added to the cache before <hours> hours ago"],
	category 	=> [ 0, "category=s", 'Search', '--category <string>', "Narrow search to matched categories (comma-separated regex list).  Defaults to substring match.  Only works with --history."],
	channel		=> [ 0, "channel=s", 'Search', '--channel <string>', "Narrow search to matched channel(s) (comma-separated regex list).  Defaults to substring match."],
	exclude		=> [ 0, "exclude=s", 'Search', '--exclude <string>', "Narrow search to exclude matched programme names (comma-separated regex list).  Defaults to substring match."],
	excludecategory	=> [ 0, "xcat|exclude-category=s", 'Search', '--exclude-category <string>', "Narrow search to exclude matched categories (comma-separated regex list).  Defaults to substring match.  Only works with --history."],
	excludechannel	=> [ 0, "xchan|exclude-channel=s", 'Search', '--exclude-channel <string>', "Narrow search to exclude matched channel(s) (comma-separated regex list).  Defaults to substring match."],
	expiresbefore		=> [ 1, "expiresbefore|expires-before=n", 'Search', '--expires-before <hours>', "Limit search to programmes that will expire in the next <hours> hours"],
	fields		=> [ 0, "fields=s", 'Search', '--fields <field1>,<field2>,...', "Searches only in the specified comma separated fields"],
	future		=> [ 1, "future!", 'Search', '--future', "Additionally search future programme schedule if it has been indexed (refresh cache with: --refresh --refresh-future)."],
	long		=> [ 0, "long|l!", 'Search', '--long, -l', "Additionally search in programme descriptions and episode names (same as --fields=name,episode,desc )"],
	search		=> [ 1, "search=s", 'Search', '--search <search term>', "GetOpt compliant way of specifying search args"],
	history		=> [ 1, "history!", 'Search', '--history', "Search/show recordings history"],
	since		=> [ 0, "since=n", 'Search', '--since <hours>', "Limit search to programmes added to the cache in the last <hours> hours"],
	type		=> [ 2, "type=s", 'Search', '--type <type>,<type>,...', "Only search in these types of programmes: ".join(',', sort keys %prog_types).",all (tv is default)"],

	# Output
	command		=> [ 1, "c|command=s", 'Output', '--command, -c <command>', "Run user command after successful recording of programme using substitution paramaters such as <dir>, <fileprefix>, <filename>, etc."],
	fileprefix	=> [ 1, "file-prefix|fileprefix=s", 'Output', '--file-prefix <format>', "The filename prefix (excluding dir and extension) using formatting fields. e.g. '<name>-<episode>-<pid>'"],
	limitprefixlength => [ 1, "limitprefixlength=n", "Output", '--limitprefixlength <length>', "The maximum length for a file prefix.  Defaults to 240 to allow space within standard 256 limit."],
	metadata	=> [ 1, "metadata=s", 'Output', '--metadata <format>', "Create metadata info file after recording.  Valid formats are: 'generic'"],
	output		=> [ 2, "output|o=s", 'Output', '--output, -o <dir>', "Recording output directory"],
	subdir		=> [ 1, "subdirs|subdir|s!", 'Output', '--subdir, -s', "Save recorded files into subdirectory.  Default: same name as programme."],
	subdirformat	=> [ 1, "subdirformat|subdirsformat|subdir-format=s", 'Output', '--subdir-format <format>', "The format to be used for subdirectory naming.  Use substitution parameters, e.g., '<nameshort>-<seriesnum>'"],
	thumbext	=> [ 1, "thumbext|thumb-ext=s", 'Output', '--thumb-ext <ext>', "Thumbnail filename extension to use"],
	thumbsizecache	=> [ 1, "thumbsizecache=n", 'Deprecated', '--thumbsizecache <index|width>', "Default thumbnail size/index to use when building cache. index: 1-11 or width: 86,150,178,512,528,640,832,1024,1280,1600,1920"],
	thumbsize	=> [ 1, "thumbsize|thumbsizemeta=n", 'Output', '--thumbsize <index|width>', "Default thumbnail size/index to use for the current recording and metadata. index: 1-11 or width: 86,150,178,512,528,640,832,1024,1280,1600,1920"],
	whitespace	=> [ 1, "whitespace|ws|w!", 'Output', '--whitespace, -w', "Keep whitespace in file and directory names.  Default behaviour is to replace whitespace with underscores."],

	# Config
	cacherebuild	=> [ 1, "rebuildcache|rebuild-cache|cacherebuild|cache-rebuild!", 'Config', '--cache-rebuild', "Rebuild cache with full 30-day programme index. Use --refresh-limit to restrict cache window."],
	cachereset	=> [ 1, "resetcache|reset-cache|cachereset|cache-reset!", 'Config', '--cache-reset', "Reset cache to retain only latest update and discard previous contents."],
	expiry		=> [ 1, "expiry|e=n", 'Config', '--expiry, -e <secs>', "Cache expiry in seconds (default 4hrs)"],
	limitmatches	=> [ 1, "limitmatches|limit-matches=n", 'Config', '--limit-matches <number>', "Limits the number of matching results for any search (and for every PVR search)"],
	nopurge		=> [ 1, "no-purge|nopurge!", 'Config', '--nopurge', "Don't ask to delete programmes recorded over 30 days ago"],
	prefsadd	=> [ 0, "addprefs|add-prefs|prefsadd|prefs-add!", 'Config', '--prefs-add', "Add/Change specified saved user or preset options"],
	prefsdel	=> [ 0, "del-prefs|delprefs|prefsdel|prefs-del!", 'Config', '--prefs-del', "Remove specified saved user or preset options"],
	prefsclear	=> [ 0, "clear-prefs|clearprefs|prefsclear|prefs-clear!", 'Config', '--prefs-clear', "Remove *ALL* saved user or preset options"],
	prefsshow	=> [ 0, "showprefs|show-prefs|prefsshow|prefs-show!", 'Config', '--prefs-show', "Show saved user or preset options"],
	preset		=> [ 1, "preset|z=s", 'Config', '--preset, -z <name>', "Use specified user options preset"],
	presetlist	=> [ 1, "listpresets|list-presets|presetlist|preset-list!", 'Config', '--preset-list', "Show all valid presets"],
	profiledir	=> [ 1, "profiledir|profile-dir=s", 'Config', '--profile-dir <dir>', "Override the user profile directory"],
	refresh		=> [ 2, "refresh|flush|f!", 'Config', '--refresh, --flush, -f', "Refresh cache"],
	refreshabortonerror	=> [ 1, "refreshabortonerror|refresh-abortonerror!", 'Config', '--refresh-abortonerror', "Abort cache refresh for programme type if data for any channel fails to download.  Use --refresh-exclude to temporarily skip failing channels."],
	refreshinclude	=> [ 1, "refreshinclude|refresh-include=s", 'Config', '--refresh-include <channel>,<channel>,...', "Include matched channel(s) when refreshing cache (comma-separated regex list).  Defaults to substring match.  Overrides --refresh-exclude-groups[-{tv,radio}] status for specified channel(s)"],
	refreshexclude	=> [ 1, "refreshexclude|refresh-exclude|ignorechannels=s", 'Config', '--refresh-exclude <channel>,<channel>,...', "Exclude matched channel(s) when refreshing cache (comma-separated regex list).  Defaults to substring match.  Overrides --refresh-include-groups[-{tv,radio}] status for specified channel(s)"],
	refreshexcludegroups	=> [ 1, "refreshexcludegroups|refresh-exclude-groups=s", 'Config', '--refresh-exclude-groups <group>,<group>,...', "Exclude channel groups when refreshing radio or TV cache (comma-separated values).  Valid values: 'national', 'regional', 'local'"],
	refreshexcludegroupsradio	=> [ 1, "refreshexcludegroupsradio|refresh-exclude-groups-radio=s", 'Config', '--refresh-exclude-groups-radio <group>,<group>,...', "Exclude channel groups when refreshing radio cache (comma-separated values).  Valid values: 'national', 'regional', 'local'"],
	refreshexcludegroupstv	=> [ 1, "refreshexcludegroupstv|refresh-exclude-groups-tv=s", 'Config', '--refresh-exclude-groups-tv <group>,<group>,...', "Exclude channel groups when refreshing TV cache (comma-separated values).  Valid values: 'national', 'regional', 'local'"],
	refreshfuture	=> [ 1, "refreshfuture|refresh-future!", 'Config', '--refresh-future', "Obtain future programme schedule when refreshing cache"],
	refreshincludegroups	=> [ 1, "refreshincludegroups|refresh-include-groups=s", 'Config', '--refresh-include-groups <group>,<group>,...', "Include channel groups when refreshing radio or TV cache (comma-separated values).  Valid values: 'national', 'regional', 'local'"],
	refreshincludegroupsradio	=> [ 1, "refreshincludegroupsradio|refresh-include-groups-radio=s", 'Config', '--refresh-include-groups-radio <group>,<group>,...', "Include channel groups when refreshing radio cache (comma-separated values).  Valid values: 'national', 'regional', 'local'"],
	refreshincludegroupstv	=> [ 1, "refreshincludegroupstv|refresh-include-groups-tv=s", 'Config', '--refresh-include-groups-tv <group>,<group>,...', "Include channel groups when refreshing TV cache (comma-separated values).  Valid values: 'national', 'regional', 'local'"],
	refreshlimit	=> [ 1, "refreshlimit|refresh-limit=n", 'Config', '--refresh-limit <days>', "Minimum number of days of programmes to cache.  Makes cache updates slow.  Default: 7 Min: 1 Max: 30"],
	refreshlimitradio	=> [ 1, "refreshlimitradio|refresh-limit-radio=n", 'Config', '--refresh-limit-radio <days>', "Number of days of radio programmes to cache.  Makes cache updates slow.  Default: 7 Min: 1 Max: 30"],
	refreshlimittv	=> [ 1, "refreshlimittv|refresh-limit-tv=n", 'Config', '--refresh-limit-tv <days>', "Number of days of TV programmes to cache.  Makes cache updates slow.  Default: 7 Min: 1 Max: 30"],
	skipdeleted	=> [ 1, "skipdeleted!", 'Config', "--skipdeleted", "Skip the download of metadata/thumbs/subs if the media file no longer exists.  Use with --history & --metadataonly/subsonly/thumbonly."],
	webrequest	=> [ 1, "webrequest=s", 'Config', '--webrequest <urlencoded string>', 'Specify all options as a urlencoded string of "name=val&name=val&..."' ],

	# Display
	conditions	=> [ 1, "conditions!", 'Display', '--conditions', 'Shows GPLv3 conditions'],
	debug		=> [ 1, "debug!", 'Display', '--debug', "Debug output"],
	dumpoptions	=> [ 1, "dumpoptions|dumpopts|dump-options|dump-opts!", 'Display', '--dump-options', 'Dumps all options with their internal option key names'],
	helpbasic	=> [ 2, "help-basic|usage|bh|hb|helpbasic|basichelp|basic-help!", 'Display', '--helpbasic, --usage', "Basic help text"],
	help		=> [ 2, "help|h!", 'Display', '--help, -h', "Intermediate help text"],
	helplong	=> [ 2, "help-long|advanced|long-help|longhelp|lh|hl|helplong!", 'Display', '--helplong', "Advanced help text"],
	hide		=> [ 1, "hide!", 'Display', '--hide', "Hide previously recorded programmes"],
	info		=> [ 2, "i|info!", 'Display', '--info, -i', "Show full programme metadata and availability of modes and subtitles (max 40 matches)"],
	list		=> [ 1, "list=s", 'Display', '--list <element>', "Show a list of distinct element values (with counts) for the selected programme type(s) and exit.  Valid elements are: 'channel'"],
	listformat	=> [ 1, "listformat=s", 'Display', '--listformat <format>', "Display programme data based on a user-defined format string containing substitution parameters (such as <pid>, <name>, <episode>, etc.)"],
	_long		=> [ 0, "", 'Display', '--long, -l', "Show extended programme info"],
	manpage		=> [ 1, "manpage=s", 'Display', '--manpage <file>', "Create man page based on current help text"],
	nocopyright	=> [ 1, "nocopyright!", 'Display', '--nocopyright', "Don't display copyright header"],
	page		=> [ 1, "page=n", 'Display', '--page <number>', "Page number to display for multipage output"],
	pagesize	=> [ 1, "pagesize=n", 'Display', '--pagesize <number>', "Number of matches displayed on a page for multipage output"],
	quiet		=> [ 1, "q|quiet!", 'Display', '--quiet, -q', "Reduce logging output"],
	series		=> [ 1, "series!", 'Display', '--series', "Display programme series names only with number of episodes"],
	showcacheage	=> [ 1, "showcacheage|show-cache-age!", 'Display', '--show-cache-age', "Display the age of the selected programme caches then exit"],
	showoptions	=> [ 1, "showoptions|showopts|show-options!", 'Display', '--show-options', 'Show options which are set and where they are defined'],
	showver		=> [ 1, "V!", 'Display', '-V', "Show get_iplayer version and exit."],
	silent		=> [ 1, "silent!", 'Display', '--silent', "No logging output except PVR download report.  Cannot be saved in preferences or PVR searches."],
	sortmatches	=> [ 1, "sortmatches|sort=s", 'Display', '--sort <fieldname>', "Field to use to sort displayed matches"],
	sortreverse	=> [ 1, "sortreverse!", 'Display', '--sortreverse', "Reverse order of sorted matches"],
	streaminfo	=> [ 1, "streaminfo!", 'Display', '--streaminfo', "Returns all of the media stream URLs of the programme(s)"],
	terse		=> [ 0, "terse!", 'Display', '--terse', "Only show terse programme info (does not affect searching)"],
	tree		=> [ 0, "tree!", 'Display', '--tree', "Display programme listings in a tree view"],
	verbose		=> [ 1, "verbose|v!", 'Display', '--verbose, -v', "Show additional output (useful for diagnosing problems)"],
	warranty	=> [ 1, "warranty!", 'Display', '--warranty', 'Displays warranty section of GPLv3'],

	# External Program

	# Misc
	encodingconsolein	=> [ 1, "encodingconsolein|encoding-console-in=s", 'Misc', '--encoding-console-in <name>', "Character encoding for standard input (currently unused).  Encoding name must be known to Perl Encode module.  Default (only if auto-detect fails): Linux/Unix/OSX = UTF-8, Windows = cp850"],
	encodingconsoleout	=> [ 1, "encodingconsoleout|encoding-console-out=s", 'Misc', '--encoding-console-out <name>', "Character encoding used to encode search results and other output.  Encoding name must be known to Perl Encode module.  Default (only if auto-detect fails): Linux/Unix/OSX = UTF-8, Windows = cp850"],
	encodinglocale	=> [ 1, "encodinglocale|encoding-locale=s", 'Misc', '--encoding-locale <name>', "Character encoding used to decode command-line arguments.  Encoding name must be known to Perl Encode module.  Default (only if auto-detect fails): Linux/Unix/OSX = UTF-8, Windows = cp1252"],
	encodinglocalefs	=> [ 1, "encodinglocalefs|encoding-locale-fs=s", 'Misc', '--encoding-locale-fs <name>', "Character encoding used to encode file and directory names.  Encoding name must be known to Perl Encode module.  Default (only if auto-detect fails): Linux/Unix/OSX = UTF-8, Windows = cp1252"],
	noindexconcurrent	=> [ 1, "noindexconcurrent|no-index-concurrent!", 'Deprecated', '--no-index-concurrent', "Do not use concurrent indexing to update programme cache.  Cache updates will be very slow."],
	indexmaxconn	=> [ 1, "indexmaxconn|index-maxconn=n", 'Misc', '--index-maxconn <number>', "Maximum number of connections to use for concurrent programme indexing.  Default: 5 Min: 1 Max: 10"],
	noscrapeversions	=> [ 1, "noscrapeversions|no-scrape-versions!", 'Deprecated', '--no-scrape-versions', "Do not scrape episode web pages as extra measure to find audiodescribed/signed versions."],
	trimhistory	=> [ 1, "trimhistory|trim-history=s", 'Misc', '--trim-history <# days to retain>', "Remove download history entries older than number of days specified in option value.  Cannot specify 0 - use 'all' to completely delete download history"],

};


# Pre-processed options instance
my $opt_pre = Options->new();
# Final options instance
my $opt = Options->new();
# Command line options instance
my $opt_cmdline = Options->new();
# Options file instance
my $opt_file = Options->new();
# Bind opt_format to Options class
Options->add_opt_format_object( $opt_format );

# Set Programme/Pvr/Streamer class global var refs to the Options instance
History->add_opt_object( $opt );
Programme->add_opt_object( $opt );
Pvr->add_opt_object( $opt );
Pvr->add_opt_file_object( $opt_file );
Pvr->add_opt_cmdline_object( $opt_cmdline );
Streamer->add_opt_object( $opt );
# Kludge: Create dummy Streamer, History and Programme instances (without a single instance, none of the bound options work)
History->new();
Programme->new();
Streamer->new();

# Print to STDERR/STDOUT if not quiet unless verbose or debug
sub logger(@) {
	my $msg = shift || '';
	# Make sure quiet can be overridden by verbose and debug options
	if ( $opt->{verbose} || $opt->{debug} || ! $opt->{silent} ) {
		# Only send messages to STDERR if pvr
		if ( $opt->{pvr} || $opt->{stderr} ) {
			print STDERR $msg;
		} else {
			print STDOUT $msg;
		}
	}
}


# fallback encodings
$opt->{encodinglocale} = $opt->{encodinglocalefs} = default_encodinglocale();
$opt->{encodingconsoleout} = $opt->{encodingconsolein} = default_encodingconsoleout();
# attempt to automatically determine encodings
eval {
	require Encode::Locale;
};
if (!$@) {
	# set encodings unless already set by PERL_UNICODE or perl -C
	$opt->{encodinglocale} = $Encode::Locale::ENCODING_LOCALE unless (${^UNICODE} & 32);
	$opt->{encodinglocalefs} = $Encode::Locale::ENCODING_LOCALE_FS unless (${^UNICODE} & 32);
	$opt->{encodingconsoleout} = $Encode::Locale::ENCODING_CONSOLE_OUT unless (${^UNICODE} & 6);
	$opt->{encodingconsolein} = $Encode::Locale::ENCODING_CONSOLE_IN unless (${^UNICODE} & 1);
}

# Pre-Parse the cmdline using the opt_format hash so that we know some of the options before we properly parse them later
# Parse options with passthru mode (i.e. ignore unknown options at this stage)
# need to save and restore @ARGV to allow later processing)
my @argv_save = @ARGV;
$opt_pre->parse( 1 );
@ARGV = @argv_save;

# set encodings ASAP
my @encoding_opts = ('encodinglocale', 'encodinglocalefs', 'encodingconsoleout', 'encodingconsolein');
foreach ( @encoding_opts ) {
	$opt->{$_} = $opt_pre->{$_} if $opt_pre->{$_};
}
binmode(STDOUT, ":encoding($opt->{encodingconsoleout})");
binmode(STDERR, ":encoding($opt->{encodingconsoleout})");
binmode(STDIN, ":encoding($opt->{encodingconsolein})");

# decode @ARGV unless already decoded by PERL_UNICODE or perl -C
unless ( ${^UNICODE} & 32 ) {
	@ARGV = map { decode($opt->{encodinglocale}, $_) } @ARGV;
}
# compose UTF-8 args if necessary
if ( $opt->{encodinglocale} =~ /UTF-?8/i ) {
	@ARGV = map { NFKC($_) } @ARGV;
}

# Copy a few options over to opt so that logger works
$opt->{debug} = $opt->{verbose} = 1 if $opt_pre->{debug};
$opt->{verbose} = 1 if $opt_pre->{verbose};
$opt->{silent} = $opt->{quiet} = 1 if $opt_pre->{silent};
$opt->{quiet} = 1 if $opt_pre->{quiet};
$opt->{pvr} = 1 if $opt_pre->{pvr};

# show version and exit
if ( $opt_pre->{showver} ) {
	print STDERR Options->copyright_notice;
	exit 0;
}

# This is where all profile data/caches/cookies etc goes
my $profile_dir;
# This is where system-wide default options are specified
my $optfile_system;

# Options directories specified by env vars
if ( defined $ENV{GETIPLAYERUSERPREFS} ) {
	$profile_dir = $opt_pre->{profiledir} || $ENV{GETIPLAYERUSERPREFS};
# Otherwise look for windows style file locations
} elsif ( defined $ENV{USERPROFILE} && $^O eq "MSWin32" ) {
	$profile_dir = $opt_pre->{profiledir} || $ENV{USERPROFILE}.'/.get_iplayer';
# Options on unix-like systems
} elsif ( defined $ENV{HOME} ) {
	$profile_dir = $opt_pre->{profiledir} || $ENV{HOME}.'/.get_iplayer';
}

# System options file specified by env var
if ( defined $ENV{GETIPLAYERSYSPREFS} ) {
	$optfile_system = $ENV{GETIPLAYERSYSPREFS};
# Otherwise look for windows style file locations
} elsif ( defined $ENV{ALLUSERSPROFILE} && $^O eq "MSWin32" ) {
	$optfile_system = $ENV{ALLUSERSPROFILE}.'/get_iplayer/options';
# System options on unix-like systems
} else {
	$optfile_system = '/etc/get_iplayer/options';
	# Show warning if this deprecated location exists and is not a symbolic link
	if ( -f '/var/lib/get_iplayer/options' && ! -l '/var/lib/get_iplayer/options' ) {
		logger "WARNING: System-wide options file /var/lib/get_iplayer/options will be deprecated in future, please use /etc/get_iplayer/options instead\n";
	}
}
# Make profile dir if it doesnt exist
mkpath $profile_dir if ! -d $profile_dir;

# default output directory on desktop for Windows
if ( ! $ENV{IPLAYER_OUTDIR} && $^O eq "MSWin32" ) {
	my $desktop;
	eval 'use Win32 qw(CSIDL_DESKTOPDIRECTORY); $desktop = Win32::GetFolderPath(CSIDL_DESKTOPDIRECTORY);';
	if ( ! $@ && $desktop ) {
		$ENV{IPLAYER_OUTDIR} = File::Spec->catfile($desktop, "iPlayer Recordings");
	}
}

# Parse cmdline opts definitions from each Programme class/subclass
Options->get_class_options( $_ ) for qw( Streamer Programme Pvr Tagger );
Options->get_class_options( progclass($_) ) for progclass();
Options->get_class_options( "Streamer::$_" ) for qw( hls );


# Parse the cmdline using the opt_format hash
Options->usage( 0 ) if not $opt_cmdline->parse();

# process --start and --stop if necessary
foreach ('start', 'stop') {
	if ($opt_cmdline->{$_} && $opt_cmdline->{$_} =~ /(\d\d):(\d\d)(:(\d\d))?/) {
		$opt_cmdline->{$_} = $1 * 3600 + $2 * 60 + $4;
	}
}

# Set the personal options according to the specified preset
my $optfile_default = "${profile_dir}/options";
my $optfile_preset;
if ( $opt_cmdline->{preset} ) {
	# create dir if it does not exist
	mkpath "${profile_dir}/presets/" if ! -d "${profile_dir}/presets/";
	# Sanitize preset file name
	my $presetname = StringUtils::sanitize_path( $opt_cmdline->{preset}, 0, 1 );
	$optfile_preset = "${profile_dir}/presets/${presetname}";
	logger "INFO: Using user options preset '${presetname}'\n";
}
logger "DEBUG: User Preset Options File: $optfile_preset\n" if defined $optfile_preset && $opt->{debug};

# Parse options if we're not saving/adding/deleting options (system-wide options are overridden by personal options)
if ( ! ( $opt_pre->{prefsadd} || $opt_pre->{prefsdel} || $opt_pre->{prefsclear} ) ) {
	# Load options from files into $opt_file
	# system, Default, './.get_iplayer/options' and Preset options in that order should they exist
	$opt_file->load( $opt, '/var/lib/get_iplayer/options', $optfile_system, $optfile_default, './.get_iplayer/options', $optfile_preset );
	# Copy these loaded options into $opt
	$opt->copy_set_options_from( $opt_file );
}


# Copy to $opt from opt_cmdline those options which are actually set
$opt->copy_set_options_from( $opt_cmdline );


# Update or show user opts file (or preset if defined) if required
if ( $opt_cmdline->{presetlist} ) {
	$opt->preset_list( "${profile_dir}/presets/" );
	exit 0;
} elsif ( $opt_cmdline->{prefsadd} ) {
	$opt->add( $opt_cmdline, $optfile_preset || $optfile_default, @ARGV );
	exit 0;
} elsif ( $opt_cmdline->{prefsdel} ) {
	$opt->del( $opt_cmdline, $optfile_preset || $optfile_default, @ARGV );
	exit 0;
} elsif ( $opt_cmdline->{prefsshow} ) {
	$opt->show( $optfile_preset || $optfile_default );
	exit 0;
} elsif ( $opt_cmdline->{prefsclear} ) {
	$opt->clear( $optfile_preset || $optfile_default );
	exit 0;
}


# Show copyright notice
logger Options->copyright_notice if not $opt->{nocopyright};

# show encodings in use
if ( $opt->{verbose} ) {
	logger "INFO: $_ = $opt->{$_}\n" for @encoding_opts;
	logger "INFO: \${^UNICODE} = ${^UNICODE}\n" if $opt->{verbose};
}

# Display prefs dirs if required
main::logger "INFO: User prefs dir: $profile_dir\n" if $opt->{verbose};
main::logger "INFO: System options dir: $optfile_system\n" if $opt->{verbose};


# Display Usage
Options->usage( 2 ) if $opt_cmdline->{helpbasic};
Options->usage( 0 ) if $opt_cmdline->{help};
Options->usage( 1 ) if $opt_cmdline->{helplong};

# Dump all option keys and descriptions if required
Options->usage( 1, 0, 1 ) if $opt_pre->{dumpoptions};

# Generate man page
Options->usage( 1, $opt_cmdline->{manpage} ) if $opt_cmdline->{manpage};

# Display GPLv3 stuff
if ( $opt_cmdline->{warranty} || $opt_cmdline->{conditions}) {
	# Get license from GNU
	logger request_url_retry( create_ua( 'get_iplayer', 1 ), 'http://www.gnu.org/licenses/gpl-3.0.txt'."\n", 1);
	exit 1;
}



########## Global vars ###########

#my @cache_format = qw/index type name pid available episode versions duration desc channel categories thumbnail timeadded guidance web/;
my @history_format = qw/pid name episode type timeadded mode filename versions duration desc channel categories thumbnail guidance web episodenum seriesnum/;
# Ranges of numbers used in the indicies for each programme type
my $max_index = 0;
for ( progclass() ) {
	# Set maximum index number
	$max_index = progclass($_)->index_max if progclass($_)->index_max > $max_index;
}

# Setup signal handlers
$SIG{INT} = $SIG{PIPE} = \&cleanup;

# Other Non option-dependent vars
my $historyfile		= "${profile_dir}/download_history";
my $cookiejar		= "${profile_dir}/cookies.";
my $namedpipe 		= "${profile_dir}/namedpipe.$$";
my $lwp_request_timeout	= 20;
my $info_limit		= 40;
my $proxy_save;

# Option dependent var definitions
my $bin;
my $binopts;
my @search_args = @ARGV;
my $memcache = {};

########### Main processing ###########

# Use --webrequest to specify options in urlencoded format
if ( $opt->{webrequest} ) {
	# parse GET args
	my @webopts = split /[\&\?]/, $opt->{webrequest};
	for (@webopts) {
		# URL decode it (value should then be decoded as UTF-8)
		$_ = decode($opt->{encodinglocale}, main::url_decode( $_ ), FB_EMPTY);
		my ( $optname, $value );
		# opt val pair
		if ( m{^\s*([\w\-]+?)[\s=](.+)$} ) {
			( $optname, $value ) = ( $1, $2 );
		# flag only
		} elsif ( m{^\s*([\w\-]+)$} ) {
			( $optname, $value ) = ( $1, 1 );
		}
		# if the option is valid then add it
		if ( defined $opt_format->{$optname} ) {
			$opt_cmdline->{$optname} = $value;
			logger "INFO: webrequest OPT: $optname=$value\n" if $opt->{verbose};
		# Ignore invalid opts
		} else {
			logger "ERROR: Invalid webrequest OPT: $optname=$value\n" if $opt->{verbose};
		}
	}
	# Copy to $opt from opt_cmdline those options which are actually set - allows pvr-add to work which only looks at cmdline args
	$opt->copy_set_options_from( $opt_cmdline );
	# Remove this option now we've processed it
	delete $opt->{webrequest};
	delete $opt_cmdline->{webrequest};
}

# Add --search option to @search_args if specified
if ( defined $opt->{search} ) {
	push @search_args, $opt->{search};
	# Remove this option now we've processed it
	delete $opt->{search};
	delete $opt_cmdline->{search};
}
# check if no search term(s) specified
my $no_search_args = $#search_args < 0;
# Assume search term is '.*' if nothing is specified - i.e. lists all programmes
push @search_args, '.*' if ! $search_args[0] && ! $opt->{pid};

# Auto-detect http://, <type>:http:// or bbc-ipd: in a search term and set it as a --pid option (disable if --fields is used).
if ( ! $opt->{pid} && ! $opt->{fields} ) {
	if ( $search_args[0] =~ m{^(\w+:)?http://} ) {
		$opt->{pid} = $search_args[0];
	}
	elsif ( $search_args[0] =~ m{^bbc-ipd:download/(\w+)/\w+/(\w+)/} ) {
		$opt->{pid} = $1;
		$opt->{modes} ||= "best" if $2 eq "hd";
	}
}

if ( $opt->{pid} ) {
	my @search_pids;
	if ( ref($opt->{pid}) eq 'ARRAY' ) {
		push @search_pids, @{$opt->{pid}};
	} else {
		push @search_pids, $opt->{pid};
	}
	$opt->{pid} = join( ',', @search_pids );
	$opt_cmdline->{pid} = $opt->{pid};
}

# PVR Lockfile location (keep global so that cleanup sub can unlink it)
my $lockfile;
$lockfile = $profile_dir.'/pvr_lock' if $opt->{pvr} || $opt->{pvrsingle} || $opt->{pvrscheduler};

# Delete cookies each session
unlink($cookiejar.'desktop');
unlink($cookiejar.'safari');
unlink($cookiejar.'coremedia');

# Create new PVR instance
# $pvr->{searchname}->{<option>} = <value>;
my $pvr = Pvr->new();
# Set some class-wide values
$pvr->setvar('pvr_dir', "${profile_dir}/pvr/" );

my $retcode = 0;
# Trim history
if ( defined($opt->{trimhistory}) ) {
	my $hist = History->new();
	$hist->trim();
# PVR functions
} elsif ( $opt->{pvradd} ) {
	if ( ! $opt->{pid} && $no_search_args ) {
		main::logger "ERROR: Search term(s) or PID required for recording\n";
		exit 1;
	}
	$pvr->add( $opt->{pvradd}, @search_args );

} elsif ( $opt->{pvrdel} ) {
	$pvr->del( $opt->{pvrdel} );

} elsif ( $opt->{pvrdisable} ) {
	$pvr->disable( $opt->{pvrdisable} );

} elsif ( $opt->{pvrenable} ) {
	$pvr->enable( $opt->{pvrenable} );

} elsif ( $opt->{pvrlist} ) {
	$pvr->display_list();

} elsif ( $opt->{pvrqueue} ) {
	if ( ! $opt->{pid} && $no_search_args ) {
		main::logger "ERROR: Search term(s) or PID required for recording\n";
		exit 1;
	}
	$pvr->queue( @search_args );

} elsif ( $opt->{pvrscheduler} ) {
	if ( $opt->{pvrscheduler} < 1800 ) {
		main::logger "ERROR: PVR schedule duration must be at least 1800 seconds\n";
		unlink $lockfile;
		exit 5;
	};
	# PVR Lockfile detection (with 12 hrs stale lockfile check)
	lockfile( 43200 ) if ! $opt->{test};
	$pvr->run_scheduler();

} elsif ( $opt->{pvr} ) {
	# PVR Lockfile detection (with 12 hrs stale lockfile check)
	lockfile( 43200 ) if ! $opt->{test};
	$retcode = $pvr->run( @search_args );
	unlink $lockfile;

} elsif ( $opt->{pvrsingle} ) {
	# PVR Lockfile detection (with 12 hrs stale lockfile check)
	lockfile( 43200 ) if ! $opt->{test};
	$retcode = $pvr->run( '^'.$opt->{pvrsingle}.'$' );
	unlink $lockfile;

# Record prog specified by --pid option
} elsif ( $opt->{pid} ) {
	my $hist = History->new();
	my @pids = split( /,/, $opt->{pid} );
	for ( @pids ) {
		$opt->{pid} = $_;
		$retcode += find_pid_matches( $hist );
	}

# Show history
} elsif ( $opt->{history} ) {
	my $hist = History->new();
	$hist->list_progs( @search_args );

# Else just process command line args
} else {
	if ( $opt->{get} && $no_search_args ) {
		main::logger "ERROR: Search term(s) required for recording\n";
		exit 1;
	}
	my $hist = History->new();
	$retcode = download_matches( $hist, find_matches( $hist, @search_args ) );
	purge_downloaded_files( $hist, 30 );
}
exit $retcode;



sub init_search {
	# Set --subtitles if --subsonly is used
	if ( $opt->{subsonly} ) {
		$opt->{subtitles} = 1;
	}

	# Set --thumbnail if --thumbonly is used
	if ( $opt->{thumbonly} ) {
		$opt->{thumb} = 1;
	}

	# Ensure lowercase types
	$opt->{type} = lc( $opt->{type} );
	# Expand 'all' type to comma separated list all prog types
	$opt->{type} = join( ',', progclass() ) if $opt->{type} =~ /(all|any)/i;

	# Force nowrite if metadata/subs/thumb-only
	if ( $opt->{metadataonly} || $opt->{subsonly} || $opt->{thumbonly} || $opt->{tagonly} ) {
		$opt->{nowrite} = 1;
	}

	# List all options and where they are set from then exit
	if ( $opt_cmdline->{showoptions} ) {
		# Show all options andf where set from
		$opt_file->display('Options from Files');
		$opt_cmdline->display('Options from Command Line');
		$opt->display('Options Used');
		logger "Search Args: ".join(' ', @search_args)."\n\n";
	}

	# Web proxy
	if ( $opt->{noproxy} ) {
		delete $opt->{proxy};
		$ENV{http_proxy} = $ENV_HTTP_PROXY;
	} else {
		(my $proxy = $opt->{proxy}) =~ s/^prepend://i;
		$opt->{proxy} = $ENV_HTTP_PROXY if not $opt->{proxy};
		# set proxy env var for child processes unless --partial-proxy
		$ENV{http_proxy} = $proxy if $proxy && ! $opt->{partialproxy};
		logger "INFO: Using Proxy $opt->{proxy}\n" if $opt->{proxy};
		logger "INFO: \$ENV{http_proxy} = $ENV{http_proxy}\n" if $ENV{http_proxy} && $opt->{verbose};
	}


	# require --metadata with --metadata-only
	if ( $opt->{metadataonly} ) {
		if ( ! $opt->{metadata} ) {
			main::logger "ERROR: Please specify metadata type using --metadata=<type>\n";
			exit 2;
		}
	}

	# hash of prog types specified
	my $type = {};
	$type->{$_} = 1 for split /,/, $opt->{type};

	# Default to type=tv if no type option is set
	$type->{tv}		= 1 if keys %{ $type } == 0;

	# Sanity check valid --type specified
	for (keys %{ $type }) {
		if ( not progclass($_) ) {
			logger "ERROR: Invalid type '$_' specified. Valid types are: ".( join ',', progclass() )."\n";
			exit 3;
		}
	}

	# exit if only showing options
	exit 0 if ( $opt_cmdline->{showoptions} );

	# Display the ages of the selected caches in seconds
	if ( $opt->{showcacheage} ) {
		for ( keys %{ $type } ) {
			my $cachefile = "${profile_dir}/${_}.cache";
			main::logger "INFO: $_ cache age: ".( time() - stat($cachefile)->mtime )." secs\n" if -f $cachefile;
		}
		exit 0;
	}

	# force --ybbcy
	$opt->{ybbcy} = 1;
	if ( defined $opt->{indexmaxconn} ) {
		$opt->{indexmaxconn} = 10 if $opt->{indexmaxconn} > 10;
		$opt->{indexmaxconn} = 1 if $opt->{indexmaxconn} < 1;
	}
	
	if ( $opt->{cacherebuild} ) {
		$opt->{cachereset} = 1;
		$opt->{refreshlimit} = 30 unless defined  $opt->{refreshlimit};
	}
	
	# Show options
	$opt->display('Current options') if $opt->{verbose};
	# $prog->{pid}->object hash
	my $prog = {};
	# obtain prog object given index. e.g. $index_prog->{$index_no}->{element};
	my $index_prog = {};
	logger "INFO: Search args: '".(join "','", @search_args)."'\n" if $opt->{verbose};

	# External Binaries
	$bin->{ffmpeg}		= $opt->{ffmpeg} || 'ffmpeg';
	if (! main::exists_in_path('ffmpeg') ) {
		$bin->{ffmpeg} = 'ffmpeg';
	}
	# ffmpeg checks
	my ($ffvs, $ffvn);
	my $ffcmd = main::encode_fs("\"$bin->{ffmpeg}\" -version 2>&1");
	my $ffout = `$ffcmd`;
	if ( $ffout =~ /ffmpeg version (\S+)/i ) {
		$ffvs = $1;
		if ( $ffvs =~ /^(\d+\.\d+)/i ) {
			$ffvn = $1;
			if ( $ffvn >= 3.0 ) {
				$opt->{ffmpeg30} = 1;
				$opt->{ffmpeg25} = 1;
			} elsif ( $ffvn >= 2.5 ) {
				$opt->{ffmpeg25} = 1;
			} elsif ( $ffvn < 1.0 ) {
				$opt->{ffmpegobsolete} = 1;
			}
		}
	}
	if ( $opt->{verbose} ) {
		main::logger "INFO: ffmpeg version string = ".($ffvs || "not found")."\n";
		main::logger "INFO: ffmpeg version number = ".($ffvn || "unknown")."\n";
	}
	$opt->{ffmpegversion} = $ffvn;
	unless ( $opt->{ffmpegversion} ) {
		if ( $bin->{ffmpeg} =~ /avconv/ || $ffout =~ /avconv/ ) {
			delete $opt->{ffmpegobsolete};
			$opt->{ffmpegav} = 1;
		}
		$opt->{ffmpegxx} = 1;
	}
	# override ffmpeg checks
	if ( $opt->{ffmpegforce} ) {
		$opt->{ffmpeg30} = 1;
		$opt->{ffmpeg25} = 1;
		delete $opt->{ffmpegav};
		delete $opt->{ffmpegxx};
	}
	delete $binopts->{ffmpeg};
	push @{ $binopts->{ffmpeg} }, ();
	if ( ! $opt->{ffmpegobsolete} ) {
		if ( $opt->{debug} ) {
			push @{ $binopts->{ffmpeg} }, ('-loglevel', 'debug');
		} elsif ( $opt->{ffmpegverbose} ) {
			push @{ $binopts->{ffmpeg} }, ('-loglevel', 'verbose');
		} elsif ( $opt->{quiet} || $opt->{silent} ) {
			push @{ $binopts->{ffmpeg} }, ('-loglevel', 'quiet');
		} else {
			push @{ $binopts->{ffmpeg} }, ('-loglevel', 'error');
		}
		if ( main::hide_progress() ) {
			push @{ $binopts->{ffmpeg} }, ( '-nostats' );
		} elsif ( ! ( $opt->{quiet} || $opt->{silent} ) ) {
			push @{ $binopts->{ffmpeg} }, ( '-stats' );
		}
	}

	$bin->{atomicparsley}	= $opt->{atomicparsley} || 'AtomicParsley';

	return ( $type, $prog, $index_prog );
}



sub find_pid_matches {
	my $hist = shift;
	my @search_args = @_;
	my ( $type, $prog, $index_prog ) = init_search( @search_args );
	my $now = time();

	# Get prog by arbitrary '<type>:<pid>' or just '<pid>' (using the specified types)(then exit)
	my @try_types;
	my $pid;

	# If $opt->{pid} is in the form of '<type>:<pid>' and <type> is a valid type
	if ( $opt->{pid} =~ m{^(.+?)\:(.+?)$} && progclass(lc($1)) ) {
		my $prog_type;
		( $prog_type, $pid )= ( lc($1), $2 );
		# Only try to recording using this prog type
		@try_types = ($prog_type);

	# $opt->{pid} is in the form of '<pid>'
	} else {
		$pid = $opt->{pid};
		@try_types = (keys %{ $type });
		# ensure tv tried first if subtitles requested and both tv and radio configured
		if ( ( $opt->{subtitles} || $opt->{subsonly} ) && $#try_types > 0 ) {
			@try_types = reverse sort @try_types;
		}
	}
	logger "INFO: Will try prog types: ".(join ',', @try_types)."\n" if $opt->{verbose};
	return 0 if ( ! ( $opt->{metadataonly} || $opt->{info} || $opt->{thumbonly} || $opt->{tagonly} || $opt->{subsonly} ) ) && $hist->check( $pid );

	# Maybe we don't want to populate caches - this slows down --pid recordings ...
	# Populate cache with all specified prog types (strange perl bug?? - @try_types is empty after these calls if done in a $_ 'for' loop!!)
	# only get links and possibly refresh caches if > 1 type is specified
	# else only load cached data from file if it exists.
	my $load_from_file_only;
	$load_from_file_only = 1 if $#try_types == 0;
	for my $t ( @try_types ) {
		get_links( $prog, $index_prog, $t, $load_from_file_only, $now );
	}

	# Simply record pid if we find it in the caches
	if ( $prog->{$pid}->{pid} ) {
		return download_pid_in_cache( $hist, $prog->{$pid} );
	}

	my $totalretcode = 0;
	my $quit_attempt = 0;
	my %done_pids;
	for my $prog_type ( @try_types ) {
		last if $quit_attempt;

		# See if the specified pid has other episode pids embedded - results in another list of pids.
		my $dummy = progclass($prog_type)->new( 'pid' => $pid, 'type' => $prog_type );
		my @pids = $dummy->get_pids_recursive();

		# Try to get pid using each specified prog type
		# process all pids in @pids
		for my $pid ( @pids ) {
			# skip this pid if we have already completed it
			next if $done_pids{$pid};
			main::logger "INFO: Trying pid: $pid using type: $prog_type\n";
			my $retcode;
			if ( not $prog->{$pid}->{pid} ) {
				$retcode = download_pid_not_in_cache( $hist, $pid, $prog_type );
				# don't try again for other types because it was recorded successfully
				$done_pids{$pid} = 1 if ! $retcode;
			} else {
				$retcode = download_pid_in_cache( $hist, $prog->{$pid} );
				# if it's in the cache then there is no need to try this pid for other types
				$done_pids{$pid} = 1;
			}
			$totalretcode += $retcode;
		}
	}

	# return zero on success of all pid recordings (used for PVR queue)
	return $totalretcode;
}



sub download_pid_not_in_cache {
	my $hist = shift;
	my $pid = shift;
	my $prog_type = shift;
	my $retcode;

	# Force prog type and create new prog instance if it doesn't exist
	my $this;
	logger "INFO: Trying to download PID using type $prog_type\n";
	logger "INFO: pid not found in $prog_type cache\n";
	$this = progclass($prog_type)->new( 'pid' => $pid, 'type' => $prog_type );
	logger "INFO: Cleaning pid Old: '$this->{pid}', " if $opt->{verbose};
	$this->clean_pid();
	logger " New: '$this->{pid}'\n" if $opt->{verbose};
	if ( $this->{pid} !~ m{^([pb]0[a-z0-9]{6})$} ) {
		logger "ERROR: Could not extract a valid PID from $this->{pid}\n";
		return 1;
	}
	# Display pid match for recording
	if ( $opt->{history} ) {
		$hist->list_progs( 'pid:'.$pid );
	} else {
		list_progs( { $this->{type} => 1 }, $this );
	}
	# Don't do a pid recording if metadataonly or thumbonly were specified
	if ( !( $opt->{metadataonly} || $opt->{thumbonly} || $opt->{subsonly} || $opt->{info} || $opt->{tagonly} ) ) {
		return $this->download_retry_loop( $hist );
	}
}



sub download_pid_in_cache {
	my $hist = shift;
	my $this = shift;
	my $retcode;

	# Prune future scheduled match if not specified
	if ( (! $opt->{future}) && Programme::get_time_string( $this->{available} ) > time() ) {
		# If the prog object exists with pid in history delete it from the prog list
		logger "INFO: Ignoring Future Prog: '$this->{index}: $this->{name} - $this->{episode} - $this->{available}'\n" if $opt->{verbose};
		# Don't attempt to download
		return 1;
	}
	logger "INFO Trying to download PID using type $this->{type}\n";
	logger "INFO: pid found in cache\n";
	# Display pid match for recording
	if ( $opt->{history} ) {
		$hist->list_progs( 'pid:'.$this->{pid} );
	} else {
		list_progs( { $this->{type} => 1 }, $this );
	}
	# Don't do a pid recording if metadataonly or thumbonly were specified
	if ( !( $opt->{metadataonly} || $opt->{thumbonly} || $opt->{subsonly} || $opt->{info} || $opt->{tagonly} ) ) {
		$retcode = $this->download_retry_loop( $hist );
	}
	return $retcode;
}



# Use the specified options to process the matches in specified array
# Usage: find_matches( $pids_history_ref, @search_args )
# Returns: array of objects to be downloaded
#      or: number of failed/remaining programmes to record using the match (excluding previously recorded progs) if --pid is specified
sub find_matches {
	my $hist = shift;
	my @search_args = @_;
	my ( $type, $prog, $index_prog ) = init_search( @search_args );
	my $now = time();

	# We don't actually need to get the links first for the specifiied type(s) if we have only index number specified (and not --list)
	my %got_cache;
	my $need_get_links = 0;
	if ( (! $opt->{list} ) ) {
		for ( @search_args ) {
			if ( (! /^[\d]+$/) || $_ > $max_index || $_ < 1 ) {
				logger "DEBUG: arg '$_' is not a programme index number - load specified caches\n" if $opt->{debug};
				$need_get_links = 1;
				last;
			}
		}
	}

	# Pre-populate caches if --list option used or there was a non-index specified
	if ( $need_get_links || $opt->{list} ) {
		# Get stream links from web site or from cache (also populates all hashes) specified in --type option
		for my $t ( keys %{ $type } ) {
			get_links( $prog, $index_prog, $t, 0, $now );
			$got_cache{ $t } = 1;
		}
	}

	# Parse remaining args
	my @match_list;
	my @index_search_args;
	for ( @search_args ) {
		chomp();

		# If Numerical value < $max_index and the object exists from loaded prog types
		if ( /^[\d]+$/ && $_ <= $max_index ) {
			if ( defined $index_prog->{$_} ) {
				logger "INFO: Search term '$_' is an Index value\n" if $opt->{verbose};
				push @match_list, $index_prog->{$_};
			} else {
				# Add to another list to search in other prog types
				push @index_search_args, $_;
			}

		# If PID then find matching programmes with 'pid:<pid>'
		} elsif ( m{^\s*pid:(.+?)\s*$}i ) {
			if ( defined $prog->{$1} ) {
				logger "INFO: Search term '$1' is a pid\n" if $opt->{verbose};
				push @match_list, $prog->{$1};
			} else {
				logger "INFO: Search term '$1' is a non-existent pid, use --pid instead and/or specify the correct programme type\n";
			}

		# Else assume this is a programme name regex
		} else {
			logger "INFO: Search term '$_' is a substring\n" if $opt->{verbose};
			push @match_list, get_regex_matches( $prog, $_ );
		}
	}

	# List elements (i.e. 'channel' 'categories') if required and exit
	if ( $opt->{list} ) {
		list_unique_element_counts( $type, $opt->{list}, @match_list );
		exit 0;
	}

	# Go get the cached data for other programme types if the index numbers require it
	for my $index ( @index_search_args ) {
		# see if this index number falls into a valid range for a prog type
		for my $prog_type ( progclass() ) {
			if ( $index >= progclass($prog_type)->index_min && $index <= progclass($prog_type)->index_max && ( ! $got_cache{$prog_type} ) ) {
				logger "DEBUG: Looking for index $index in $prog_type type\n" if $opt->{debug};
				# Get extra required programme caches
				logger "INFO: Additionally getting cached programme data for $prog_type\n" if $opt->{verbose};
				# Add new prog types to the type list
				$type->{$prog_type} = 1;
				# Get $prog_type stream links
				get_links( $prog, $index_prog, $prog_type, 0, $now );
				$got_cache{$prog_type} = 1;
			}
		}
		# Now check again if the index number exists in the cache before adding this prog to the match list
		if ( defined $index_prog->{$index}->{pid} ) {
			push @match_list, $index_prog->{$index} if defined $index_prog->{$index}->{pid};
		} else {
			logger "WARNING: Unmatched programme index '$index' specified - ignoring\n";
		}
	}

	# De-dup matches and retain order
	@match_list = main::make_array_unique_ordered( @match_list );

	# Prune out pids already recorded if opt{hide} is specified
	if ( $opt->{hide} && ( not $opt->{force} ) ) {
		my @pruned;
		for my $this (@match_list) {
			# If the prog object exists with pid in history delete it from the prog list
			if ( $hist->check( $this->{pid}, 1 ) ) {
				logger "DEBUG: Ignoring Prog: '$this->{index}: $this->{name} - $this->{episode}'\n" if $opt->{debug};
			} else {
				push @pruned, $this;
			}
		}
		@match_list = @pruned;
	}

	# Prune future scheduled matches if not specified
	if ( ! $opt->{future} ) {
		my $now = time();
		my @pruned;
		for my $this (@match_list) {
			# If the prog object exists with pid in history delete it from the prog list
			my $available = Programme::get_time_string( $this->{available} );
			if ( $available && ( $available > $now ) ) {
				logger "DEBUG: Ignoring Future Prog: '$this->{index}: $this->{name} - $this->{episode} - $this->{available}'\n" if $opt->{debug};
			} else {
				push @pruned, $this;
			}
		}
		@match_list = @pruned;
	}

	# Truncate the array of matches if --limit-matches is specified
	if ( $opt->{limitmatches} && $#match_list > $opt->{limitmatches} - 1 ) {
		$#match_list = $opt->{limitmatches} - 1;
		main::logger "WARNING: The list of matching results was limited to $opt->{limitmatches} by --limit-matches\n";
	}

	# Display list for recording
	list_progs( $type, @match_list );

	return @match_list;
}



sub download_matches {
	my $hist = shift;
	my @match_list = @_;

	# Do the recordings based on list of index numbers if required
	my $failcount = 0;
	if ( $opt->{get} ) {
		for my $this (@match_list) {
			$failcount += $this->download_retry_loop( $hist );
		}
	}

	return $failcount;
}



# Usage: list_progs( \%type, @prog_refs )
# Lists progs given an array of index numbers
sub list_progs {
	my $typeref = shift;
	# Use a rogue value if undefined
	my $number_of_types = keys %{$typeref} || 2;
	my $ua = create_ua( 'desktop', 1 );
	my %names;
	my ( @matches ) = ( @_ );


	# Setup user agent for a persistent connection to get programme metadata
	if ( $opt->{info} ) {
		# Truncate array if were lisiting info and > $info_limit entries are requested - be nice to the beeb!
		if ( $#matches >= $info_limit ) {
			$#matches = $info_limit - 1;
			logger "WARNING: Only processing the first $info_limit matches\n";
		}
	}

	# Sort array by specified field
	if ( $opt->{sortmatches} ) {
		# disable tree mode
		delete $opt->{tree};

		# Lookup table for numeric search fields
		my %sorttype = (
			index		=> 1,
			duration	=> 1,
			timeadded	=> 1,
			expires => 1,
		);
		my $sort_prog;
		for my $this ( @matches ) {
			# field needs to be made to be unique by adding '|pid'
			$sort_prog->{ "$this->{ $opt->{sortmatches} }|$this->{pid}" } = $this;
		}
		@matches = ();
		# Numeric search
		if ( defined $sorttype{ $opt->{sortmatches} } ) {
			for my $key ( sort {$a <=> $b} keys %{ $sort_prog } ) {
				push @matches, $sort_prog->{$key};
			}
		# alphanumeric search
		} else {
			for my $key ( sort {lc $a cmp lc $b} keys %{ $sort_prog } ) {
				push @matches, $sort_prog->{$key};
			}
		}
	}
	# Reverse sort?
	if ( $opt->{sortreverse} ) {
		my @tmp = reverse @matches;
		@matches = @tmp;
	}

	# Determine number of episodes for each name
	my %episodes;
	my $episode_width;
	if ( $opt->{series} ) {
		for my $this (@matches) {
			$episodes{ $this->{name} }++;
			$episode_width = length( $this->{name} ) if length( $this->{name} ) > $episode_width;
		}
	}

	# Sort display order by field (won't work in tree mode)


	# Calculate page sizes etc if required
	my $items = $#matches+1;
	my ( $pages, $page, $pagesize, $first, $last );
	if ( ! $opt->{page} ) {
		logger "Matches:\n" if $#matches >= 0;
	} else {
		$pagesize = $opt->{pagesize} || 25;
		# Calc first and last programme numbers
		$first = $pagesize * ( $opt->{page} - 1 );
		$last = $first + $pagesize;
		# How many pages
		$pages = int( $items / $pagesize ) + 1;
		# If we request a page that is too high
		$opt->{page} = $pages if $page > $pages;
		logger "Matches (Page $opt->{page}/${pages}".()."):\n" if $#matches >= 0;
	}
	# loop through all programmes in match
	for ( my $count=0; $count < $items; $count++ ) {
		my $this = $matches[$count];
		# Only display if the prog name is set
		if ( ( ! $opt->{page} ) || ( $opt->{page} && $count >= $first && $count < $last ) ) {
			if ( $this->{name} || ! ( $opt->{series} || $opt->{tree} ) ) {
				# Tree mode
				if ( $opt->{tree} ) {
					if (! defined $names{ $this->{name} }) {
						$this->list_entry( '', 0, $number_of_types );
						$names{ $this->{name} } = 1;
					} else {
						$this->list_entry( '', 1, $number_of_types );
					}
				# Series mode
				} elsif ( $opt->{series} ) {
					if (! defined $names{ $this->{name} }) {
						$this->list_entry( '', 0, $number_of_types, $episodes{ $this->{name} }, $episode_width );
						$names{ $this->{name} } = 1;
					}
				# Normal mode
				} else {
					$this->list_entry( '', 0, $number_of_types ) if ( $this->{name} );
				}
			}
		}
		# Get info, create metadata, subtitles, tag and/or thumbnail file (i.e. don't stream/record)
		if ( $opt->{info} || $opt->{metadataonly} || $opt->{thumbonly} || $opt->{subsonly} || $opt->{tagonly} || $opt->{streaminfo} ) {
			$this->get_metadata_general();
			if ( $this->get_metadata( $ua ) ) {
				main::logger "ERROR: Could not get programme metadata\n" if $opt->{verbose};
				next;
			}
			# Search versions for versionlist versions
			my @versions = $this->generate_version_list;

			# Use first version in list if a version list is not specified
			$this->{version} = $versions[0] || 'default';
			$this->generate_filenames( $ua, $this->file_prefix_format() );
			# info
			$this->display_metadata( sort keys %{ $this } ) if $opt->{info};
			# subs (only for tv)
			if ( $opt->{subsonly} && $this->{type} eq 'tv') {
				$this->create_dir();
				$this->download_subtitles( $ua, "$this->{dir}/$this->{fileprefix}.srt", \@versions );
			}
			# metadata
			if ( $opt->{metadataonly} ) {
				$this->create_dir();
				$this->create_metadata_file;
			}
			# thumbnail
			if ( $opt->{thumbonly} && $this->{thumbnail} ) {
				$this->create_dir();
				$this->download_thumbnail();
			}
			# tag
			if ( $opt->{tagonly} && ! $opt->{notag} ) {
				# this probably needs to be initialised earlier - needed for tagging
				$bin->{atomicparsley} = $opt->{atomicparsley} || 'AtomicParsley';
				$this->create_dir();
				$this->tag_file;
			}
			# streaminfo
			if ( $opt->{streaminfo} ) {
				main::display_stream_info( $this, $this->{verpids}->{$this->{version}}, $this->{version} );
			}
			# remove offending metadata
			delete $this->{filename};
			delete $this->{filepart};
			delete $this->{ext};
		}
	}
	logger "\nINFO: ".($#matches + 1)." Matching Programmes\n" if ( $opt->{pvr} && $#matches >= 0 ) || ! $opt->{pvr};
}



# Returns matching programme objects using supplied regex
# Usage: get_regex_matches ( \%prog, $regex )
sub get_regex_matches {
	my $prog = shift;
	my $download_regex = shift;

	my %download_hash;
	my ( $channel_regex, $category_regex, $versions_regex, $channel_exclude_regex, $category_exclude_regex, $exclude_regex );

	if ( $opt->{channel} ) {
		$channel_regex = '('.(join '|', ( split /,/, $opt->{channel} ) ).')';
	} else {
		$channel_regex = '.*';
	}
	if ( $opt->{category} ) {
		$category_regex = '('.(join '|', ( split /,/, $opt->{category} ) ).')';
	} else {
		$category_regex = '.*';
	}
	if ( $opt->{excludechannel} ) {
		$channel_exclude_regex = '('.(join '|', ( split /,/, $opt->{excludechannel} ) ).')';
	} else {
		$channel_exclude_regex = '^ROGUE$';
	}
	if ( $opt->{excludecategory} ) {
		$category_exclude_regex = '('.(join '|', ( split /,/, $opt->{excludecategory} ) ).')';
	} else {
		$category_exclude_regex = '^ROGUE$';
	}
	if ( $opt->{exclude} ) {
		$exclude_regex = '('.(join '|', ( split /,/, $opt->{exclude} ) ).')';
	} else {
		$exclude_regex = '^ROGUE$';
	}
	my $since = $opt->{since} || 999999;
	my $before = $opt->{before} || -999999;
	my $now = time();
	my $available_since = strftime('%Y-%m-%dT%H:%M:%S', gmtime($now - ($opt->{availablesince} * 3600))) if $opt->{availablesince};
	my $expires_before = $now + ($opt->{expiresbefore} * 3600) if $opt->{expiresbefore};

	if ( $opt->{verbose} ) {
		main::logger "DEBUG: Search download_regex = $download_regex\n";
		main::logger "DEBUG: Search channel_regex = $channel_regex\n";
		main::logger "DEBUG: Search category_regex = $category_regex\n";
		main::logger "DEBUG: Search exclude_regex = $exclude_regex\n";
		main::logger "DEBUG: Search channel_exclude_regex = $channel_exclude_regex\n";
		main::logger "DEBUG: Search category_exclude_regex = $category_exclude_regex\n";
		main::logger "DEBUG: Search since = $since\n";
		main::logger "DEBUG: Search before = $before\n";
		main::logger "DEBUG: Search available_since = $available_since\n";
		main::logger "DEBUG: Search expires_before = $expires_before\n";
	}

	# Determine fields to search
	my @searchfields;
	# User-defined fields list
	if ( $opt->{fields} ) {
		@searchfields = split /\s*,\s*/, lc( $opt->{fields} );
	# Also search long descriptions and episode data if -l is specified
	} elsif ( $opt->{long} ) {
		@searchfields = ( 'name', 'episode', 'desc' );
	# Default to name search only
	} else {
		@searchfields = ( 'name' );
	}

	# Loop through each prog object
	for my $this ( values %{ $prog } ) {
		# Only include programmes matching channels and category regexes
		if ( $this->{channel} =~ /$channel_regex/i
			&& $this->{categories} =~ /$category_regex/i
			&& $this->{channel} !~ /$channel_exclude_regex/i
			&& $this->{categories} !~ /$category_exclude_regex/i
			&& ( ( not defined $this->{timeadded} ) || $this->{timeadded} >= $now - ($since * 3600) )
			&& ( ( not defined $this->{timeadded} ) || $this->{timeadded} < $now - ($before * 3600) )
			&& ( ( not $available_since ) || ( not $this->{available} ) || $this->{available} ge $available_since )
			&& ( ( not $expires_before ) || ( not $this->{expires} ) || $this->{expires} <= $expires_before )
		) {
			# Add included matches
			my @compund_fields;
			push @compund_fields, $this->{$_} for @searchfields;
			$download_hash{ $this->{index} } = $this if (join ' ', @compund_fields) =~ /$download_regex/i;
		}
	}
	# Remove excluded matches
	for my $field ( @searchfields ) {
		for my $index ( keys %download_hash ) {
			my $this = $download_hash{$index};
			delete $download_hash{$index} if $this->{ $field } =~ /$exclude_regex/i;
		}
	}
	my @match_list;
	# Add all matching prog objects to array
	for my $index ( sort {$a <=> $b} keys %download_hash ) {
		push @match_list, $download_hash{$index};
	}

	return @match_list;
}



# Usage: sort_index( \%prog, \%index_prog, [$prog_type], [sortfield] )
# Populates the index if the prog hash as well as creating the %index_prog hash
# Should be run after any number of get_links methods
sub sort_index {
	my $prog = shift;
	my $index_prog = shift;
	my $prog_type = shift;
	my $sortfield = shift || 'name';
	my $counter = 1;
	my @sort_key;

	# Add index field based on alphabetical sorting by $sortfield
	# Start index counter at 'min' for this prog type
	$counter = progclass($prog_type)->index_min if defined $prog_type;

	# Create unique array of '<$sortfield|pid>' for this prog type
	for my $pid ( keys %{$prog} ) {
		# skip prog not of correct type and type is defined
		next if defined $prog_type && $prog->{$pid}->{type} ne $prog_type;
		push @sort_key, "$prog->{$pid}->{$sortfield}|$pid";
	}
	# Sort by $sortfield and index
	for (sort @sort_key) {
		# Extract pid
		my $pid = (split /\|/)[1];

		# Insert prog instance var of the index number
		$prog->{$pid}->{index} = $counter;

		# Add the object reference into %index_prog hash
		$index_prog->{ $counter } = $prog->{$pid};

		# Increment the index counter for this prog type
		$counter++;
	}
	return 0;
}



sub make_array_unique_ordered {
	# De-dup array and retain order (don't ask!)
	my ( @array ) = ( @_ );
	my %seen = ();
	my @unique = grep { ! $seen{ $_ }++ } @array;
	return @unique;
}



# User Agents
# Uses global $ua_cache
my $ua_cache = {};
sub user_agent {
	my $id = shift || 'desktop';

	# Create user agents lists
	my $user_agent = {
		get_iplayer	=> [ "get_iplayer/$version $^O/$^V" ],
		desktop		=> [
				'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.81 Safari/537.36',
				'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.12; rv:53.0) Gecko/20100101 Firefox/53.0',
				'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/55.0.2883.87 Safari/537.36 OPR/42.0.2393.94',
				'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_4) AppleWebKit/603.1.30 (KHTML, like Gecko) Version/10.1 Safari/603.1.30',
				'Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.81 Safari/537.36',
				'Mozilla/5.0 (Windows NT 6.1; rv:53.0) Gecko/20100101 Firefox/53.0',
				'Mozilla/5.0 (Windows NT 6.1; Trident/7.0; rv:11.0) like Gecko',
				'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.81 Safari/537.36',
				'Mozilla/5.0 (Windows NT 10.0; WOW64; rv:53.0) Gecko/20100101 Firefox/53.0',
				'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.79 Safari/537.36 Edge/14.14393',
				'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:53.0) Gecko/20100101 Firefox/53.0',
				'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.81 Safari/537.36',
			],
	};

	# Remember the ua string for the entire session
	my $uas = $ua_cache->{$id};
	if ( ! $uas ) {
		# Randomize strings
		my @ualist = @{ $user_agent->{$id} };
		$uas = $ualist[rand @ualist];
		my $code = sprintf( "%03d", int(rand(1000)) );
		$uas =~ s/<RAND>/$code/g;
		$ua_cache->{$id} = $uas;
	}
	logger "DEBUG: Using $id user-agent string: '$uas'\n" if $opt->{debug};
	return $uas || '';
}



# Returns classname for prog type or if not specified, an array of all prog types
sub progclass {
	my $prog_type = shift;
	if ( $prog_type ) {
		return $prog_types{$prog_type};
	} elsif ( not defined $prog_type ) {
		return keys %prog_types;
	} else {
		main::logger "ERROR: Programe Type '$prog_type' does not exist. Try using --refresh\n";
		exit 3;
	}
}



# Returns classname for prog type or if not specified, an array of all prog types
sub is_prog_type {
	my $prog_type = shift;
	return 1 if defined $prog_types{$prog_type};
	return 0;
}



# Feed Info:
#	# aod index
#	http://www.bbc.co.uk/radio/aod/index_noframes.shtml [ceased]
# # schedule feeds
#	http://www.bbc.co.uk/bbcthree/programmes/schedules.xml [ceased]
#	http://www.bbc.co.uk/radio4/programmes/schedules/this_week
#	# These need drill-down to get episodes:
#	# TV schedules by date
#	http://www.bbc.co.uk/iplayer/widget/schedule/service/cbeebies/date/20080704	[ceased]
#	# TV schedules in JSON, Yaml or XML
#	http://www.bbc.co.uk/<channel>/programmes/schedules.(json|yaml|xml) [ceased]
#	# prog schedules by channel / date
#	http://www.bbc.co.uk/iplayer/schedules/bbcone/20170429
#	http://www.bbc.co.uk/iplayer/schedules/<channel>/programmes/schedules/<year>/<week>.(json|yaml|xml) [ceased]
#	# TV index on programmes
#	http://www.bbc.co.uk/iplayer/a-z/a
#	# All TV (limit has effect of limiting to 2.? times number entries kB??)
#	# seems that only around 50% of progs are available here compared to programmes site:
#	http://feeds.bbc.co.uk/iplayer/categories/tv/list/limit/200 [ceased]
#	# Search feed
#	http://feeds.bbc.co.uk/iplayer/<channel>/<searchword>/list [ceased]
#	# All Radio
#	http://feeds.bbc.co.uk/iplayer/categories/radio/list/limit/999 [ceased]
#	# New:
#	# iCal feeds see: http://www.bbc.co.uk/blogs/radiolabs/2008/07/some_ical_views_onto_programme.shtml [ceased]
#	http://bbc.co.uk/programmes/b0079cmw/episodes/player.ics [ceased]
#	# Other data
#	http://www.bbc.co.uk/cbbc/programmes/genres/childrens/player [ceased]
#	http://www.bbc.co.uk/programmes/genres/childrens/schedules/upcoming.ics	[ceased]
#
# Usage: get_links( \%prog, \%index_prog, <prog_type>, <only load from file flag> )
# Globals: $memcache
sub get_links {
	my $prog = shift;
	my $index_prog = shift;
	my $prog_type = shift;
	my $only_load_from_cache = shift;
	my $now = shift || time();
	# Define cache file format (this is overridden by the header line of the cache file)
	my @cache_format = qw/index type name pid available expires episode seriesnum episodenum versions duration desc channel categories thumbnail timeadded guidance web/;

	my $cachefile = "${profile_dir}/${prog_type}.cache";

	# Read cache into $pid_old and $index_prog_old hashes if cache exists
	my $prog_old = {};
	my $index_prog_old = {};

	# By pass re-sorting and get straight from memcache if possible
	if ( keys %{ $memcache->{$prog_type} } && -f $cachefile && ! $opt->{refresh} ) {
		for my $pid ( keys %{ $memcache->{$prog_type} } ) {
			# Create new prog instance
			$prog->{$pid} = progclass( lc($memcache->{$prog_type}->{$pid}->{type}) )->new( 'pid' => $pid );
			# Deep-copy of elements in memcache prog instance to %prog
			$prog->{$pid}->{$_} = $memcache->{$prog_type}->{$pid}->{$_} for @cache_format;
			# Copy object reference into index_prog hash
			$index_prog->{ $prog->{$pid}->{index} } = $prog->{$pid};
		}
		logger "INFO: Got (quick) ".(keys %{ $memcache->{$prog_type} })." memcache entries for $prog_type\n" if $opt->{verbose};
		return 0;
	}

	# Open cache file (need to verify we can even read this)
	if ( -f $cachefile && open(CACHE, "< $cachefile") ) {
		my @cache_format_old = @cache_format;
		# Get file format and contents less any comments
		while (<CACHE>) {
			chomp();
			# Get cache format if specified
			if ( /^\#(.+?\|){3,}/ ) {
				@cache_format_old = split /[\#\|]/;
				shift @cache_format_old;
				logger "INFO: Cache format from existing $prog_type cache file: ".(join ',', @cache_format_old)."\n" if $opt->{debug};
				next;
			}
			# Ignore comments
			next if /^[\#\s]/;
			# Populate %prog_old from cache
			# Get cache line
			my @record = split /\|/;
			my $record_entries;
			# Update fields in %prog_old hash for $pid
			$record_entries->{$_} = shift @record for @cache_format_old;
			$prog_old->{ $record_entries->{pid} } = $record_entries;
			# Copy pid into index_prog_old hash
			$index_prog_old->{ $record_entries->{index} } = $record_entries->{pid};
		}
		close (CACHE);
		logger "INFO: Got ".(keys %{ $prog_old })." file cache entries for $prog_type\n" if $opt->{verbose};

	# Else no mem or file cache
	} else {
		logger "INFO: No file cache exists for $prog_type\n" if $opt->{verbose};
	}


	# Do we need to refresh the cache ?
	# if a cache file doesn't exist/corrupted/empty, refresh option is specified or original file is older than $cache_sec then download new data
	my $cache_secs = $opt->{expiry} || main::progclass( $prog_type )->expiry() || 14400;
	main::logger "DEBUG: Cache expiry time for $prog_type is ${cache_secs} secs - refresh in ".( stat($cachefile)->mtime + $cache_secs - $now )." secs\n" if $opt->{debug} && -f $cachefile && ! $opt->{refresh};
	if ( (! $only_load_from_cache) &&
		( (! keys %{ $prog_old } ) || (! -f $cachefile) || $opt->{refresh} || ($now >= ( stat($cachefile)->mtime + $cache_secs )) || $opt->{cachereset} )
	) {

		# Get links for specific type of programme class into %prog
		if ( progclass( $prog_type )->get_links( $prog, $prog_type, $now ) != 0 ) {
			# failed - leave cache unchanged
			main::logger "\nERROR: Errors encountered when indexing $prog_type programmes - skipping\n";
			return 0;
		}

		# Back up cache file before write
		my $oldcachefile = "${cachefile}.old";
		if ( -e $cachefile && ! copy($cachefile, $oldcachefile) ) {
			die "ERROR: Cannot copy $cachefile to $oldcachefile: $!\n";
		}
		if ( ! $opt->{cachereset} && $prog_type =~ /^(radio|tv)$/ ) {
			my $min_timeadded = $now - (30 * 86400);
			# Retain old cache entries that are not expired or superseded
			for my $pid ( keys %{$prog_old} ) {
				if ( ! $prog_old->{$pid}->{expires} || $prog_old->{$pid}->{expires} < $now || $prog_old->{$pid}->{timeadded} < $min_timeadded ) {
					main::logger "DEBUG: Expired: $prog_type - $pid - $prog_old->{$pid}->{name} - $prog_old->{$pid}->{episode} expires=$prog_old->{$pid}->{expires} timeadded=$prog_old->{$pid}->{timeadded} now=$now\n" if $opt->{debug};
				}
				elsif ( ! $prog->{$pid} && $prog_old->{$pid} ) {
					$prog->{$pid} = main::progclass($prog_type)->new(%{$prog_old->{$pid}});
				}
			}
		}

		# Sort index for this prog type from cache file
		# sorts and references %prog objects into %index_prog
		sort_index( $prog, $index_prog, $prog_type );

		# Open cache file for writing
		unlink $cachefile;
		if ( open(CACHE, "> $cachefile") ) {
			print CACHE "#".(join '|', @cache_format)."\n";
			# loop through all progs just obtained through get_links above (in numerical index order)
			for my $index ( sort {$a <=> $b} keys %{$index_prog} ) {
				# prog object
				my $this = $index_prog->{ $index };
				# Only write entries for correct prog type
				if ( $this->{type} eq $prog_type ) {
					# Merge old and new data to retain timestamps
					if ( $opt->{ybbcy} && $prog_old->{ $this->{pid} }->{available} ) {
						$this->{available} = $prog_old->{ $this->{pid} }->{available};
					}
					# if the entry was in old cache then retain timestamp from old entry
					if ( $prog_old->{ $this->{pid} }->{timeadded} ) {
						$this->{timeadded} = $prog_old->{ $this->{pid} }->{timeadded};
					# Else this is a new entry
					} else {
						$this->{timeadded} = $now;
						$this->list_entry( 'Added: ' ) unless $opt->{quiet};
					}
					# Write each field into cache line
					print CACHE $this->{$_}.'|' for @cache_format;
					print CACHE "\n";
				}
			}
			close (CACHE);
		} else {
			logger "WARNING: Couldn't open cache file '$cachefile' for writing\n";
		}

		# Copy new progs into memcache
		for my $index ( keys %{ $index_prog } ) {
			my $pid = $index_prog->{ $index }->{pid};
			# Update fields in memcache from %prog hash for $pid
			$memcache->{$prog_type}->{$pid}->{$_} = $index_prog->{$index}->{$_} for @cache_format;
		}

		# purge pids in memcache that aren't in %prog
		for my $pid ( keys %{ $memcache->{$prog_type} } ) {
			if ( ! defined $prog->{$pid} ) {
				delete $memcache->{$prog_type}->{$pid};
				main::logger "DEBUG: Removed PID $pid from memcache\n" if $opt->{debug};
			}
		}


	# Else copy data from existing cache file into new prog instances and memcache
	} else {
		for my $pid ( keys %{ $prog_old } ) {

			# Create new prog instance
			$prog->{$pid} = progclass( lc($prog_old->{$pid}->{type}) )->new( 'pid' => $pid );

			# Deep-copy the data from %prog_old into %prog and $memcache->{$prog_type}
			for (@cache_format) {
				$prog->{$pid}->{$_} = $prog_old->{$pid}->{$_};
				# Update fields in memcache from %prog_old hash for $pid
				$memcache->{$prog_type}->{$pid}->{$_} = $prog_old->{$pid}->{$_};
			}

		}
		# Add prog objects to %index_prog hash
		$index_prog->{$_} = $prog->{ $index_prog_old->{$_} } for keys %{ $index_prog_old };
	}

	return 0;
}



# Generic
# Returns an offset timestamp given an srt begin or end timestamp and offset in ms
sub subtitle_offset {
	my ( $timestamp, $offset ) = @_;
	my ( $hr, $min, $sec, $ms ) = split /[:,\.]/, $timestamp;
	# split into hrs, mins, secs, ms
	my $ts = $ms + $sec*1000 + $min*60*1000 + $hr*60*60*1000 + $offset;
	$hr = int( $ts/(60*60*1000) );
	$ts -= $hr*60*60*1000;
	$min = int( $ts/(60*1000) );
	$ts -= $min*60*1000;
	$sec = int( $ts/1000 );
	$ts -= $sec*1000;
	$ms = $ts;
	return sprintf( '%02d:%02d:%02d,%03d', $hr, $min, $sec, $ms );
}



# Generic
sub display_stream_info {
	my ($prog, $verpid, $version) = (@_);
	# default version is 'default'
	$version = 'default' if not defined $verpid;
	# Get stream data if not defined
	if ( not defined $prog->{streams}->{$version} ) {
		logger "INFO: Getting media stream metadata for $prog->{name} - $prog->{episode}, $verpid ($version)\n" if $prog->{pid};
		$prog->{streams}->{$version} = $prog->get_stream_data( $verpid, undef, $version );
	}
	for my $prog_type ( sort keys %{ $prog->{streams}->{$version} } ) {
		logger "stream:     $prog_type\n";
		for my $entry ( sort keys %{ $prog->{streams}->{$version}->{$prog_type} } ) {
			logger sprintf("%-11s %s\n", $entry.':', $prog->{streams}->{$version}->{$prog_type}->{$entry} );
		}
		logger "\n";
	}
	return 0;
}



sub proxy_disable {
	my $ua = shift;
	$ua->proxy( ['http'] => undef );
	$proxy_save = $opt->{proxy};
	delete $opt->{proxy};
	main::logger "INFO: Disabled proxy: $proxy_save\n" if $opt->{verbose};
}



sub proxy_enable {
	my $ua = shift;
	$ua->proxy( ['http'] => $opt->{proxy} ) if $opt->{proxy} && $opt->{proxy} !~ /^prepend:/;
	$opt->{proxy} = $proxy_save;
	main::logger "INFO: Restored proxy to $opt->{proxy}\n" if $opt->{verbose};
}



# Generic
# create_ua( <agentname>|'', [<cookie mode>] )
# cookie mode:	0: retain cookies
#		1: no cookies
#		2: retain cookies but discard if site requires it
sub create_ua {
	my $id = shift || '';
	my $nocookiejar = shift || 0;
	# Use either the key from the function arg if it exists or a random ua string
	my $agent = main::user_agent( $id ) || main::user_agent( 'desktop' );
	my $ua = LWP::UserAgent->new;
	$ua->timeout( $lwp_request_timeout );
	$ua->proxy( ['http'] => $opt->{proxy} ) if $opt->{proxy} && $opt->{proxy} !~ /^prepend:/;
	$ua->agent( $agent );
	# Using this slows down stco parsing!!
	#$ua->default_header( 'Accept-Encoding', 'gzip,deflate' );
	$ua->conn_cache(LWP::ConnCache->new());
	#$ua->conn_cache->total_capacity(50);
	$ua->cookie_jar( HTTP::Cookies->new( file => $cookiejar.$id, autosave => 1, ignore_discard => 1 ) ) if not $nocookiejar;
	$ua->cookie_jar( HTTP::Cookies->new( file => $cookiejar.$id, autosave => 1 ) ) if $nocookiejar == 2;
	main::logger "DEBUG: Using ".($nocookiejar ? "NoCookies " : "cookies.$id " )."user-agent '$agent'\n" if $opt->{debug};
	return $ua;
};



# Generic
# Gets the contents of a URL and retries if it fails, returns '' if no page could be retrieved
# Usage <content> = request_url_retry(<ua>, <url>, <retries>, <succeed message>, [<fail message>], <1=mustproxy>, [<fail_content>] );
sub request_url_retry {

	my %OPTS = @LWP::Protocol::http::EXTRA_SOCK_OPTS;
	$OPTS{SendTE} = 0;
	@LWP::Protocol::http::EXTRA_SOCK_OPTS = %OPTS;

	my ($ua, $url, $retries, $succeedmsg, $failmsg, $mustproxy, $fail_content) = @_;
	my $res;


	# Use url prepend if required
	if ( defined $opt->{proxy} && $opt->{proxy} =~ /^prepend:/ ) {
		$url = $opt->{proxy}.main::url_encode( $url );
		$url =~ s/^prepend://g;
	}

	# Malformed URL check
	if ( $url !~ m{^\s*https?\:\/\/}i ) {
		logger "ERROR: Malformed URL: '$url'\n";
		return '';
	}

	# Disable proxy unless mustproxy is flagged
	main::proxy_disable($ua) if $opt->{partialproxy} && ! $mustproxy;
	my $i;
	logger "INFO: Getting page $url\n" if $opt->{verbose};
	for ($i = 0; $i < $retries; $i++) {
		$res = $ua->request( HTTP::Request->new( GET => $url ) );
		if ( ! $res->is_success ) {
			logger $failmsg if $i == $retries - 1;
		} else {
			logger $succeedmsg;
			last;
		}
	}
	# Re-enable proxy unless mustproxy is flagged
	main::proxy_enable($ua) if $opt->{partialproxy} && ! $mustproxy;
	# Return empty string if we failed and content not required
	return '' if $i == $retries and ! $fail_content;

	# Only return decoded content if gzip is used - otherwise this severely slows down stco scanning! Perl bug?
	main::logger "DEBUG: ".($res->header('Content-Encoding') || 'No')." Encoding used on $url\n" if $opt->{debug};
	# this appears to be obsolete
	# return $res->decoded_content if defined $res->header('Content-Encoding') && $res->header('Content-Encoding') eq 'gzip';
	# return $res->content;
	return $res->decoded_content;
}



# Generic
# Checks if a particular program exists (or program.exe) in the $ENV{PATH} or if it has a path already check for existence of file
sub exists_in_path {
	my $name = shift;
	my $bin = $bin->{$name};
	# Strip quotes around binary if any just for checking
	$bin =~ s/^"(.+)"$/$1/g;
	# If this has a path specified, does file exist
	return 1 if $bin =~ /[\/\\]/ && (-x ${bin} || -x "${bin}.exe");
	# Search PATH
	for (@PATH) {
		return 1 if -x "${_}/${bin}" || -x "${_}/${bin}.exe";
	}
	return 0;
}



# Generic
# Checks history for files that are over 30 days old and asks user if they should be deleted
# "$prog->{pid}|$prog->{name}|$prog->{episode}|$prog->{type}|".time()."|$prog->{mode}|$prog->{filename}\n";
sub purge_downloaded_files {
	my $hist = shift;
	my @delete;
	my @proglist;
	my $days = shift;

	# Return if disabled or running in a typically non-interactive mode
	return 0 if $opt->{nopurge} || $opt->{nowrite} || $opt->{quiet} || $opt->{silent};

	for my $pid ( $hist->get_pids() ) {
		my $record = $hist->get_record( $pid );
		if ( $record->{timeadded} < (time() - $days*86400) && $record->{filename} && -f $record->{filename} ) {
			# Calculate the seconds difference between epoch_now and epoch_datestring and convert back into array_time
			my @t = gmtime( time() - $record->{timeadded} );
			push @proglist, "$record->{name} - $record->{episode}, Recorded: $t[7] days $t[2] hours ago";
			push @delete, $record->{filename};
		}
	}

	if ( @delete ) {
		main::logger "\nThese programmes should be deleted:\n";
		main::logger "-----------------------------------\n";
		main::logger join "\n", @proglist;
		main::logger "\n-----------------------------------\n";
		main::logger "Do you wish to delete them now (Yes/No) ?\n";
		my $answer = <STDIN>;
		if ($answer =~ /^yes$/i ) {
			for ( @delete ) {
				main::logger "INFO: Deleting $_\n";
				unlink $_;
			}
			main::logger "Programmes deleted\n";
		} else {
			main::logger "No Programmes deleted\n";
		}
	}

	return 0;
}



# Returns url decoded string
sub url_decode {
	my $str = shift;
	$str =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
	return $str;
}



# Returns url encoded string
sub url_encode {
	my $str = shift;
	$str =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
	return $str;
}



# list_unique_element_counts( \%type, $element_name, @matchlist);
# Show channels for currently specified types in @matchlist - an array of progs
sub list_unique_element_counts {
	my $typeref = shift;
	my $element_name = shift;
	my @match_list = @_;
	my %elements;
	logger "INFO: ".(join ',', keys %{ $typeref })." $element_name List:\n" if $opt->{verbose};
	# Get list to count from matching progs
	for my $prog ( @match_list ) {
		my @element;
		# Need to separate the categories
		if ($element_name eq 'categories') {
			@element = split /,/, $prog->{$element_name};
		} else {
			$element[0] = $prog->{$element_name};
		}
		for my $element (@element) {
			$elements{ $element }++;
		}
	}
	# display element + prog count
	logger "$_ ($elements{$_})\n" for sort keys %elements;
	return 0;
}



# Invokes command in @args as a system call (hopefully) without using a shell
# Can also redirect all stdout and stderr to either: STDOUT, STDERR or unchanged
# Usage: run_cmd( <normal|STDERR|STDOUT>, @args )
# Returns: exit code
sub run_cmd {
	my $mode = shift;
	my @cmd = ( @_ );
	my $rtn;
	my $USE_SYSTEM = 0;
	#my $system_suffix;
	local *DEVNULL;

	my $log_str;
	my @log_cmd = @cmd;
	if ( $#log_cmd > 0 ) {
		$log_str = (join ' ', map {s/\"/\\\"/g; "\"$_\"";} @log_cmd)
	} else {
		$log_str = $log_cmd[0]
	}
	main::logger "\n\nINFO: Command: $log_str\n\n" if $opt->{verbose};

	# Define what to do with STDOUT and STDERR of the child process
	my $fh_child_out = ">&STDOUT";
	my $fh_child_err = ">&STDERR";

	$mode = 'QUIET' if ( $opt->{quiet} || $opt->{silent} ) && ! ($opt->{debug} || $opt->{verbose});

	if ( $mode eq 'STDOUT' ) {
		$fh_child_out = $fh_child_err = ">&STDOUT";
		#$system_suffix = '2>&1';
	} elsif ( $mode eq 'STDERR' ) {
		$fh_child_out = $fh_child_err = ">&STDERR";
		#$system_suffix = '1>&2';
	} elsif ( $mode =~ /^QUIET/ ) {
		open(DEVNULL, ">", File::Spec->devnull()) || die "ERROR: Cannot open null device\n";
		if ( $mode eq 'QUIET_STDOUT' ) {
			$fh_child_out = ">&DEVNULL";
		} elsif ( $mode eq 'QUIET_STDERR' ) {
			$fh_child_err = ">&DEVNULL";
		} else {
			$fh_child_out = $fh_child_err = ">&DEVNULL";
		}
	}

	# Check if we have IPC::Open3 otherwise fallback on system()
	eval "use IPC::Open3";

	# use system(); - probably only likely in win32
	if ($@) {
		main::logger "WARNING: Please download and run latest installer - 'IPC::Open3' is not available\n";
		#push @cmd, $system_suffix;
		my $rtn = system( @cmd );

	# use system() regardless
	} elsif ( $USE_SYSTEM ) {
		#push @cmd, $system_suffix;
		my $rtn = system( @cmd );

	# Use open3()
	} else {

		my $procid;
		# Don't create zombies - unfortunately causes open3 to return -1 exit code regardless!
		##### local $SIG{CHLD} = 'IGNORE';
		# Setup signal handler for SIGTERM/INT/KILL - kill, kill, killlllll
		$SIG{TERM} = $SIG{PIPE} = $SIG{INT} = sub {
			my $signal = shift;
			main::logger "\nINFO: Cleaning up (signal = $signal), killing PID=$procid:";
			for my $sig ( qw/INT TERM KILL/ ) {
				# Kill process with SIGs (try to allow proper handling of kill by child process)
				if ( $opt->{verbose} ) {
					main::logger "\nINFO: $$ killing cmd PID=$procid with SIG${sig}";
				} else {
					main::logger '.';
				}
				kill $sig, $procid;
				sleep 1;
				if ( ! kill 0, $procid ) {
					main::logger "\nINFO: $$ killed cmd PID=$procid\n";
					last;
				}
				sleep 1;
			}
			main::logger "\n";
			exit 0;
		};

		# Don't use NULL for the 1st arg of open3 otherwise we end up with a messed up STDIN once it returns
		$procid = open3( 0, $fh_child_out, $fh_child_err, @cmd );

		# Wait for child to complete
		waitpid( $procid, 0 );
		$rtn = $?;

		# Restore old signal handlers
		$SIG{TERM} = $SIGORIG{TERM};
		$SIG{PIPE} = $SIGORIG{PIPE};
		$SIG{INT} = $SIGORIG{INT};
		#$SIG{CHLD} = $SIGORIG{CHLD};
	}
	close(DEVNULL);

	# Interpret return code	and force return code 2 upon error
	my $return = $rtn >> 8;
	if ( $rtn == -1 ) {
		main::logger "ERROR: Command failed to execute: $!\n" if $opt->{verbose};
		$return = 2 if ! $return;
	} elsif ( $rtn & 128 ) {
		main::logger "WARNING: Command executed but coredumped\n" if $opt->{verbose};
		$return = 2 if ! $return;
	} elsif ( $rtn & 127 ) {
		main::logger sprintf "WARNING: Command executed but died with signal %d\n", $rtn & 127 if $opt->{verbose};
		$return = 2 if ! $return;
	}
	main::logger sprintf "INFO: Command exit code %d (raw code = %d)\n", $return, $rtn if $return || $opt->{verbose};
	return $return;
}



# Generic
# Escape chars in string for shell use
sub StringUtils::esc_chars {
	# will change, for example, a!!a to a\!\!a
	$_[0] =~ s/([;<>\*\|&\$!#\(\)\[\]\{\}:'"])/\\$1/g;
}



sub StringUtils::clean_utf8_and_whitespace {
	# Remove non utf8
	$_[0] =~ s/[^\x{21}-\x{7E}\s\t\n\r]//g;
	# Strip beginning/end/extra whitespace
	$_[0] =~ s/\s+/ /g;
	$_[0] =~ s/(^\s+|\s+$)//g;
}

# Remove diacritical marks
sub StringUtils::remove_marks {
	my $string = shift;
	$string = NFKD($string);
	$string =~ s/\pM//g;
	return $string;
}

# Convert unwanted punctuation to ASCII
sub StringUtils::convert_punctuation {
	my $string = shift;
	# die smart quotes die
	$string =~ s/[\x{0060}\x{00B4}\x{2018}\x{2019}\x{201A}\x{2039}\x{203A}]/'/g;
	$string =~ s/[\x{201C}\x{201D}\x{201E}]/"/g;
	$string =~ s/[\x{2013}\x{2014}]/-/g;
	$string =~ s/[\x{2026}]/.../g;
	return $string;
}

# Generic
# Make a filename/path sane
sub StringUtils::sanitize_path {
	my $string = shift;
	my $is_path = shift || 0;
	my $force_default = shift || 0;
	my $punct_bad = '[!"#$%&\'()*+,:;<=>?@[\]^`{|}~]';
	# Replace forward slashes with _ if not path
	$string =~ s/\//_/g unless $is_path;
	# Replace backslashes with _ if not Windows path
	$string =~ s/\\/_/g unless $^O eq "MSWin32" && $is_path;
	# use ISO8601 dates
	$string =~ s|(\d\d)[/_](\d\d)[/_](20\d\d)|$3-$2-$1|g;
	# ASCII-fy some punctuation
	$string = StringUtils::convert_punctuation($string);
	# Remove non-ASCII chars
	$string = StringUtils::remove_marks($string);
	$string =~ s/[^\x{20}-\x{7e}]//g;
	# Truncate duplicate colon/semi-colon/comma
	$string =~ s/([:;,])(\1)+/$1/g;
	# Add whitespace behind colon/semi-colon/comma if not present
	$string =~ s/([:;,])(\S)/$1 $2/g;
	# Remove most punctuation chars
	# Includes invalid chars for FAT and HFS
	$string =~ s/$punct_bad//g;
	# Replace ellipsis
	$string =~ s/\.{3}/_/g;
	# Remove extra/leading/trailing whitespace
	$string =~ s/\s+/ /g;
	$string =~ s/(^\s+|\s+$)//g;
	# Replace whitespace with _ unless --whitespace
	$string =~ s/\s/_/g unless ( $opt->{whitespace} && ! $force_default );
	# Truncate multiple replacement chars
	$string =~ s/_+/_/g;
	return $string;
}


# Generic
# Signal handler to clean up after a ctrl-c or kill
sub cleanup {
	my $signal = shift;
	logger "\nINFO: Cleaning up $0 (got signal $signal)\n"; # if $opt->{verbose};
	unlink $namedpipe;
	unlink $lockfile;
	# Execute default signal handler
	$SIGORIG{$signal}->() if ref($SIGORIG{$signal}) eq 'CODE';
	exit 1;
}


# Uses: global $lockfile
# Lock file detection (<stale_secs>)
# Global $lockfile
sub lockfile {
	my $stale_time = shift || 86400;
	my $now = time();
	# if lockfile exists then quit as we are already running
	if ( -T $lockfile ) {
		if ( ! open (LOCKFILE, $lockfile) ) {
			main::logger "ERROR: Cannot read lockfile '$lockfile'\n";
			exit 1;
		}
		my @lines = <LOCKFILE>;
		close LOCKFILE;

		# If the process is still running and the lockfile is newer than $stale_time seconds
		if ( kill(0,$lines[0]) > 0 && $now < ( stat($lockfile)->mtime + $stale_time ) ) {
				main::logger "ERROR: Quitting - process is already running ($lockfile)\n";
				# redefine cleanup sub so that it doesn't delete $lockfile
				$lockfile = '';
				exit 0;
		} else {
			main::logger "INFO: Removing stale lockfile\n" if $opt->{verbose};
			unlink ${lockfile};
		}
	}
	# write our PID into this lockfile
	if (! open (LOCKFILE, "> $lockfile") ) {
		main::logger "ERROR: Cannot write to lockfile '${lockfile}'\n";
		exit 1;
	}
	print LOCKFILE $$;
	close LOCKFILE;
	return 0;
}



sub expand_list {
	my $list = shift;
	my $search = shift;
	my $replace = shift;
	my @elements = split /,/, $list;
	for (@elements) {
		$_ = $replace if $_ eq $search;
	}
	return join ',', @elements;
}



# Converts any number words (or numbers) 0 - 99 to a number
sub convert_words_to_number {
	my $text = shift;
	$text = lc($text);
	my $number = 0;
	# Regex for mnemonic numbers
	my %lookup_0_19 = qw(
		zero		0
		one		1
		two		2
		three		3
		four		4
		five		5
		six		6
		seven		7
		eight		8
		nine		9
		ten		10
		eleven		11
		twelve		12
		thirteen	13
		fourteen	14
		fifteen		15
		sixteen		16
		seventeen	17
		eighteen	18
		nineteen	19
	);
	my %lookup_tens = qw(
		twenty	20
		thirty	30
		forty 	40
		fifty	50
		sixty	60
		seventy	70
		eighty	80
		ninety	90
	);
	my $regex_units = '(zero|one|two|three|four|five|six|seven|eight|nine)';
	my $regex_ten_to_nineteen = '(ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)';
	my $regex_tens = '(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)';
	my $regex_numbers = '(\d+|'.$regex_units.'|'.$regex_ten_to_nineteen.'|'.$regex_tens.'((\s+|\-|)'.$regex_units.')?)';
	#print "REGEX: $regex_numbers\n";
	#my $text = 'seventy two'
	$number += $text if $text =~ /^\d+$/;
	my $regex = $regex_numbers.'$';
	if ( $text =~ /$regex/ ) {
		# trailing zero -> nineteen
		$regex = '('.$regex_units.'|'.$regex_ten_to_nineteen.')$';
		$number += $lookup_0_19{ $1 } if $text =~ /($regex)/;
		# leading tens
		$regex = '^('.$regex_tens.')(\s+|\-|_||$)';
		$number += $lookup_tens{ $1 } if $text =~ /$regex/;
	}
	return $number;
}



# Returns a regex string that matches all number words (or numbers) 0 - 99
sub regex_numbers {
	my $regex_units = '(zero|one|two|three|four|five|six|seven|eight|nine)';
	my $regex_ten_to_nineteen = '(ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)';
	my $regex_tens = '(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)';
	return '(\d+|'.$regex_units.'|'.$regex_ten_to_nineteen.'|'.$regex_tens.'((\s+|\-|)'.$regex_units.')?)';
}


sub default_encodinglocale {
	return 'UTF-8' if (${^UNICODE} & 32);
	return ($^O eq "MSWin32" ? 'cp1252' : 'UTF-8');
}


sub default_encodingconsoleout {
	return 'UTF-8' if (${^UNICODE} & 6);
	return ($^O eq "MSWin32" ? 'cp850' : 'UTF-8');
}


sub encode_fs {
	my $string = shift;
	return $string if $opt->{encodinglocalefs} =~ /UTF-?8/i;
	return encode($opt->{encodinglocalefs}, $string, FB_EMPTY);
}

sub hide_progress {
	unless ( $opt->{logprogress} || $opt->{debug} ) {
		if ( $opt->{pvr} || $opt->{stderr} ) {
			return ! -t STDERR;
		} else {
			return ! -t STDOUT;
		}
	}
	return 0;
}

############## OO ################

############## Options default class ################
package Options;

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use Getopt::Long;
use strict;

# Class vars
# Global options
my $opt_format_ref;
# Constructor
# Usage: $opt = Options->new( 'optname' => 'testing 123', 'myopt2' => 'myval2', <and so on> );
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	bless $self, $type;
}


# Use to bind a new options ref to the class global $opt_format_ref var
sub add_opt_format_object {
	my $self = shift;
	$Options::opt_format_ref = shift;
}


# Parse cmdline opts using supplied hash
# If passthru flag is set then no error will result if there are unrecognised options etc
# Usage: $opt_cmdline->parse( [passthru] );
sub parse {
	my $this = shift;
	my $pass_thru = shift;
	my $opt_format_ref = $Options::opt_format_ref;
	# Build hash for passing to GetOptions module
	my %get_opts;

	for my $name ( grep !/^_/, keys %{$opt_format_ref} ) {
		my $format = @{ $opt_format_ref->{$name} }[1];
		$get_opts{ $format } = \$this->{$name};
	}

	# Allow bundling of single char options
	Getopt::Long::Configure("bundling");
	if ( $pass_thru ) {
		Getopt::Long::Configure("pass_through");
	} else {
		Getopt::Long::Configure("no_pass_through");
	}

	# cmdline opts take precedence
	# get options
	return GetOptions(%get_opts);
}



sub copyright_notice {
	shift;
	my $text = "get_iplayer $version_text, ";
	$text .= <<'EOF';
Copyright (C) 2008-2010 Phil Lewis
  This program comes with ABSOLUTELY NO WARRANTY; for details use --warranty.
  This is free software, and you are welcome to redistribute it under certain
  conditions; use --conditions for details.

  NOTE: A UK TV licence is required to legally access BBC iPlayer TV content

EOF
	return $text;
}



# Usage: $opt_cmdline->usage( <helplevel>, <manpage>, <dump> );
sub usage {
	my $this = shift;
	# Help levels: 0:Intermediate, 1:Advanced, 2:Basic
	my $helplevel = shift;
	my $manpage = shift;
	my $dumpopts = shift;
	my $opt_format_ref = $Options::opt_format_ref;
	my %section_name;
	my %name_syntax;
	my %name_args;
	my %name_desc;
	my @usage;
	my @man;
	my @dump;
	push @man,
		'.TH GET_IPLAYER "1" "May 2017" "Phil Lewis" "get_iplayer Manual"',
		'.SH NAME', 'get_iplayer - Stream Recording tool and PVR for BBC iPlayer',
		'.SH SYNOPSIS',
		'\fBget_iplayer\fR [<options>] [<regex|index> ...]',
		'.PP',
		'\fBget_iplayer\fR \fB--get\fR [<options>] <regex|index> ...',
		'.br',
		'\fBget_iplayer\fR <url> [\fB--type\fR=<type> <options>]',
		'.PP',
		'\fBget_iplayer\fR <pid> [\fB--type\fR=<type> <options>]',
		'.PP',
		'\fBget_iplayer\fR \fB--refresh\fR [\fB--type\fR=<type> <options>]',
		'.SH DESCRIPTION',
		'\fBget_iplayer\fR lists, searches and records BBC iPlayer TV and radio programmes.',
		'.PP',
		'\fBget_iplayer\fR has two modes: recording a complete programme for later playback, and as a Personal Video Recorder (PVR), subscribing to',
		'search terms and recording programmes automatically.',
		'.PP',
		'If given no arguments, \fBget_iplayer\fR updates and displays the list of currently available TV programmes.',
		'Use --type=radio for radio programmes Each available programme has an alphanumeric identifier (\fBPID\fR).',
		'.PP',
		'In PVR mode, \fBget_iplayer\fR can be called from cron to record programmes on a schedule.',
		'.SH "OPTIONS"' if $manpage;
	push @usage, 'Usage ( Also see https://github.com/get-iplayer/get_iplayer/wiki/documentation ):';
	push @usage, ' List All Programmes:            get_iplayer [--type=<TYPE>]';
	push @usage, ' Search Programmes:              get_iplayer <REGEX>';
	push @usage, ' Record Programmes by Search:    get_iplayer <REGEX> --get';
	push @usage, ' Record Programmes by Index:     get_iplayer <INDEX> --get';
	push @usage, ' Record Programmes by URL:       get_iplayer [--type=<TYPE>] "<URL>"';
	push @usage, ' Record Programmes by PID:       get_iplayer [--type=<TYPE>] --pid=<PID>';
	push @usage, '';
	push @usage, ' Update get_iplayer cache:       get_iplayer --refresh [--type=<TYPE>] [--force]';
	push @usage, '';
	push @usage, ' Basic Help:                     get_iplayer --basic-help' if $helplevel != 2;
	push @usage, ' Intermediate Help:              get_iplayer --help' if $helplevel == 2;
	push @usage, ' Advanced Help:                  get_iplayer --long-help' if $helplevel != 1;

	for my $name (keys %{$opt_format_ref} ) {
		next if not $opt_format_ref->{$name};
		my ( $helpmask, $format, $section, $syntax, $desc ) = @{ $opt_format_ref->{$name} };
		# Skip advanced options if not req'd
		next if $helpmask == 1 && $helplevel != 1;
		# Skip internediate options if not req'd
		next if $helpmask != 2 && $helplevel == 2;
		push @{$section_name{$section}}, $name if $syntax;
		$name_syntax{$name} = $syntax;
		if ( $format =~ /!$/ ) {
			$name_args{$name} = "1";
		} elsif ( $syntax =~ / (<.*)$/ ) {
			$name_args{$name} = $1;
		}
		$name_desc{$name} = $desc;
	}

	# Build the help usage text
	# Each section
	for my $section ( 'Search', 'Display', 'Recording', 'Download', 'Output', 'PVR', 'Config', 'External Program', 'Tagging', 'Misc', 'Deprecated' ) {
		next if not defined $section_name{$section};
		my @lines;
		my @manlines;
		my @dumplines;
		#Runs the PVR using all saved PVR searches (intended to be run every hour from cron etc)
		push @man, ".SS \"$section Options:\"" if $manpage;
		push @dump, '', "$section Options:" if $dumpopts;
		push @usage, '', "$section Options:" if $section ne 'Deprecated' or $helplevel == 1;
		# Each name in this section array
		my $xo = Options->excludeopts;
		for my $name ( sort @{ $section_name{$section} } ) {
			push @manlines, '.TP'."\n".'\fB'.$name_syntax{$name}."\n".$name_desc{$name} if $manpage;
			my $dumpname = $name;
			$dumpname = undef if $dumpname =~ /$xo/;
			if ( $dumpname ) {
				$dumpname =~ s/^_//g;
				$dumpname .= " $name_args{$name}" if $name_args{$name};
			}
			push @dumplines, sprintf(" %-51s %-46s %s", $name_syntax{$name}, $dumpname, $name_desc{$name} ) if $dumpopts;
			push @lines, sprintf(" %-51s %s", $name_syntax{$name}, $name_desc{$name} );
		}
		push @usage, sort @lines if $section ne 'Deprecated' or $helplevel == 1;;
		push @man, sort @manlines;
		push @dump, sort @dumplines;
	}

	# Create manpage
	if ( $manpage ) {
		push @man,
			'.SH AUTHOR',
			'get_iplayer was written by Phil Lewis <iplayer2 (at sign) linuxcentre.net> and is now maintained by the contributors at http://www.infradead.org/get_iplayer/html/get_iplayer.html',
			'.PP',
			'This manual page was originally written by Jonathan Wiltshire <jmw@debian.org> for the Debian project (but may be used by others).',
			'.SH COPYRIGHT NOTICE';
		push @man, Options->copyright_notice;
		# Escape '-'
		s/\-/\\-/g for @man;
		# Open manpage file and write contents
		if (! open (MAN, "> $manpage") ) {
			main::logger "ERROR: Cannot write to manpage file '$manpage'\n";
			exit 1;
		}
		print MAN join "\n", @man, "\n";
		close MAN;
		main::logger "INFO: Wrote manpage file '$manpage'\n";
		exit 0;

	# Print options dump and quit
	} elsif ( $dumpopts ) {
		main::logger join "\n", @dump, "\n";

	# Print usage and quit
	} else {
		main::logger join "\n", @usage, "\n";
	}

	exit 0;
}


# Add all the options into supplied hash from specified class
# Usage: Options->get_class_options( 'Programme:tv' );
sub get_class_options {
	shift;
	my $classname = shift;
	my $opt_format_ref = $Options::opt_format_ref;
	# If the method exists...
	eval { $classname->opt_format() };
	if ( ! $@ ) {
		my %tmpopt = %{ $classname->opt_format() };
		for my $thisopt ( keys %tmpopt ) {
			$opt_format_ref->{$thisopt} = $tmpopt{$thisopt};
		}
	}
}


# Copies values in one instance to another only if they are set with a value/defined
# Usage: $opt->copy_set_options_from( $opt_cmdline );
sub copy_set_options_from {
	my $this_to = shift;
	my $this_from = shift;
	# Merge cmdline options into $opt instance (only those options defined)
	for ( keys %{$this_from} ) {
		$this_to->{$_} = $this_from->{$_} if defined $this_from->{$_};
	}
}



# specify regex of options that cannot be saved
sub excludeopts {
	return '^(cache|profiledir|encoding|silent|help|debug|get|pvr|prefs|preset|warranty|conditions|dumpoptions|comment)';
}


# List all available presets in the specified dir
sub preset_list {
	my $opt = shift;
	my $dir = shift;
	main::logger "INFO: Valid presets: ";
	if ( opendir( DIR, "${profile_dir}/presets/" ) ) {
		my @preset_list = grep !/(^\.|~$)/, readdir DIR;
		closedir DIR;
		main::logger join ',', @preset_list;
	}
	main::logger "\n";
}


# Clears all option entries for a particular preset (i.e. deletes the file)
sub clear {
	my $opt = shift;
	my $prefsfile = shift;
	$opt->show( $prefsfile );
	unlink $prefsfile;
	main::logger "INFO: Removed all above options from $prefsfile\n";
}


# $opt->add( $opt_cmdline, $optfile, @search_args )
# Add/change cmdline-only options to file
sub add {
	my $opt = shift;
	my $this_cmdline = shift;
	my $optfile = shift;
	my @search_args = @_;

	# Load opts file
	my $entry = get( $opt, $optfile );

	# Add search args to opts
	if ( defined $this_cmdline->{search} ) {
		push @search_args, $this_cmdline->{search};
	}
	$this_cmdline->{search} = '('.(join '|', @search_args).')' if @search_args;

	# Merge all cmdline opts into $entry except for these
	my $regex = $opt->excludeopts;
	for ( grep !/$regex/, keys %{ $this_cmdline } ) {
		# if this option is on the cmdline
		if ( defined $this_cmdline->{$_} ) {
			main::logger "INFO: Changed option '$_' from '$entry->{$_}' to '$this_cmdline->{$_}'\n" if defined $entry->{$_} && $this_cmdline->{$_} ne $entry->{$_};
			main::logger "INFO: Added option '$_' = '$this_cmdline->{$_}'\n" if not defined $entry->{$_};
			$entry->{$_} = $this_cmdline->{$_};
		}
	}

	# Save opts file
	put( $opt, $entry, $optfile );
}



# $opt->add( $opt_cmdline, $optfile )
# Add/change cmdline-only options to file
sub del {
	my $opt = shift;
	my $this_cmdline = shift;
	my $optfile = shift;
	my @search_args = @_;
	return 0 if ! -f $optfile;

	# Load opts file
	my $entry = get( $opt, $optfile );

	# Add search args to opts
	$this_cmdline->{search} = '('.(join '|', @search_args).')' if @search_args;

	# Merge all cmdline opts into $entry except for these
	my $regex = $opt->excludeopts;
	for ( grep !/$regex/, keys %{ $this_cmdline } ) {
		main::logger "INFO: Deleted option '$_' = '$entry->{$_}'\n" if defined $this_cmdline->{$_} && defined $entry->{$_};
		delete $entry->{$_} if defined $this_cmdline->{$_};
	}

	# Save opts file
	put( $opt, $entry, $optfile );
}



# $opt->show( $optfile )
# show options from file
sub show {
	my $opt = shift;
	my $optfile = shift;
	return 0 if ! -f $optfile;

	# Load opts file
	my $entry = get( $opt, $optfile, 1 );

	# Merge all cmdline opts into $entry except for these
	main::logger "Options in '$optfile'\n";
	my $regex = $opt->excludeopts;
	for ( keys %{ $entry } ) {
		main::logger "\t$_ = $entry->{$_}\n";
	}
}



# $opt->save( $opt_cmdline, $optfile )
# Save cmdline-only options to file
sub put {
	my $opt = shift;
	my $entry = shift;
	my $optfile = shift;

	unlink $optfile;
	main::logger "DEBUG: adding/changing options to $optfile:\n" if $opt->{debug};
	open (OPT, "> $optfile") || die ("ERROR: Cannot save options to $optfile\n");
	for ( keys %{ $entry } ) {
		if ( defined $entry->{$_} ) {
			print OPT "$_ $entry->{$_}\n";
			main::logger "DEBUG: Saving option $_ = $entry->{$_}\n" if $opt->{debug};
		}
	}
	close OPT;

	main::logger "INFO: Options file $optfile updated\n";
	return;
}



# Returns a hashref of 'optname => internal_opt_name' for all options
sub get_opt_map {
	my $opt_format_ref = $Options::opt_format_ref;

	# Get a hash or optname -> internal_opt_name
	my $optname;
	for my $optint ( keys %{ $opt_format_ref } ) {
		my $format = @{ $opt_format_ref->{$optint} }[1];
		#main::logger "INFO: Opt Format '$format'\n";
		$format =~ s/=.*$//g;
		# Parse each option format
		for ( split /\|/, $format ) {
			next if /^$/;
			#main::logger "INFO: Opt '$_' -> '$optint'\n";
			if ( defined $optname->{$_} ) {
				main::logger "ERROR: Duplicate Option defined '$_' -> '$optint' and '$optname->{$_}'\n";
				exit 11;
			}
			$optname->{$_} = $optint;
		}
	}
	for my $optint ( keys %{ $opt_format_ref } ) {
		$optname->{$optint} = $optint;
	}
	return $optname;
}


# $entry = get( $opt, $optfile )
# get all options from file into $entry ($opt is used just to get access to general options like debug)
sub get {
	my $opt = shift;
	my $optfile = shift;
	my $suppress_warnings = shift;
	my $opt_format_ref = $Options::opt_format_ref;
	my $entry;
	return $entry if ( ! defined $optfile ) || ( ! -f $optfile );

	my $optname = get_opt_map();

	my (@ignored, @deprecated);
	# Load opts
	main::logger "DEBUG: Parsing options from $optfile:\n" if $opt->{debug};
	my $opt_encoding = ( $^O eq "MSWin32" && $optfile eq $optfile_system ) ? $opt->{encodinglocalefs} : "utf8";
	open (OPT, "<:encoding($opt_encoding)", $optfile) || die ("ERROR: Cannot read options file $optfile\n");
	while(<OPT>) {
		next unless (/^\s*([\w\-_]+)\s+(.*)\s*$/);
		# Error if the option is not valid
		if ( not defined $optname->{$1} ) {
			push @ignored, "$1 = $2";
			next;
		}
		# Warn if it is listed as a deprecated internal option name
		if ( defined @{ $opt_format_ref->{$1} }[2] ) {
			if ( @{ $opt_format_ref->{$1} }[2] eq 'Deprecated' ) {
				push @deprecated, "$1 = $2";
			}
		}
		chomp( $entry->{ $optname->{$1} } = $2 );
		main::logger "DEBUG: Loaded option $1 ($optname->{$1}) = $2\n" if $opt->{debug};
	}
	close OPT;
	unless ( $suppress_warnings ) {
		# Force error to go to STDERR (prevents PVR runs getting STDOUT warnings)
		$opt->{stderr} = 1;
		if ( @ignored ) {
			main::logger "WARNING: Ignoring invalid option(s) in $optfile:\n";
			for my $ignored ( @ignored ) {
				main::logger "WARNING: $ignored\n";
			}
			main::logger "WARNING: Please remove invalid options from $optfile\n";
		}
		if ( @deprecated ) {
			main::logger "WARNING: Deprecated option(s) found in $optfile:\n";
			for my $deprecated ( @deprecated ) {
				main::logger "WARNING: $deprecated\n";
			}
			main::logger "WARNING: Deprecated options will be removed in a future release\n";
		}
		main::logger "INFO: Use --dump-options to display all valid options\n" if @deprecated or @ignored;
		delete $opt->{stderr};
	}
	return $entry;
}



# $opt_file->load( $opt, $optfile )
# Load default options from file(s) into instance
sub load {
	my $this_file = shift;
	my $opt = shift;
	my @optfiles = ( @_ );

	# If multiple files are specified, load them in order listed
	for my $optfile ( @optfiles ) {
		# Load opts
		my $entry = get( $opt, $optfile );
		# Copy to $this_file instance
		$this_file->copy_set_options_from( $entry );
	}

	return;
}



# Usage: $opt_file->display( [<exclude regex>], [<title>] );
# Display options
sub display {
	my $this = shift;
	my $title = shift || 'Options';
	my $excluderegex = shift || 'ROGUEVALUE';
	my $regex = $this->excludeopts;
	main::logger "$title:\n";
	for ( sort keys %{$this} ) {
		if ( defined $this->{$_} && $this->{$_} ) {
			if ( ref($this->{$_}) eq 'ARRAY' ) {
				main::logger "\t$_ = ".(join(',', @{$this->{$_}}))."\n";
			} else {
				main::logger "\t$_ = $this->{$_}\n";
			}
		}
	}
	main::logger "\n";
	return 0;
}




########################################################

################ History default class #################
package History;

use Encode;
use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use strict;

# Class vars
# Global options

# Constructor
# Usage: $hist = History->new();
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	## Ensure the subclass $opt var is pointing to the Superclass global optref
	$opt = $History::optref;
	bless $self, $type;
}


# $opt->{<option>} access method
sub opt {
	my $self = shift;
	my $optname = shift;
	return $opt->{$optname};
}


# Use to bind a new options ref to the class global $opt_ref var
sub add_opt_object {
	my $self = shift;
	$History::optref = shift;
}


sub trim {
	my $oldhistoryfile = "$historyfile.old";
	my $newhistoryfile = "$historyfile.new";
	if ( $opt->{trimhistory} =~ /^all$/i ) {
		if ( ! copy($historyfile, $oldhistoryfile) ) {
			die "ERROR: Cannot copy $historyfile to $oldhistoryfile: $!\n";
		}
		if ( ! unlink($historyfile) ) {
			die "ERROR: Cannot delete $historyfile: $! \n";
		}
		main::logger "INFO: Deleted all entries from download history\n";
		return;
	}
	if ( $opt->{trimhistory} !~ /^\d+$/ ) {
		die "ERROR: --trim-history option must have a positive integer value, or use 'all' to completely delete download history.\n";
	}
	if ( $opt->{trimhistory} =~ /^0+$/ ) {
		die "ERROR: Cannot specify 0 for --trim-history option.  Use 'all' to completely delete download history.\n";
	}
	if ( ! open(HIST, "< $historyfile") ) {
		die "ERROR: Cannot read from $historyfile\n";
	}
	if ( ! open(NEWHIST, "> $newhistoryfile") ) {
		die "ERROR: Cannot write to $newhistoryfile\n";
	}
	my $trim_limit = time() - ($opt->{trimhistory} * 86400);
	my $deleted_count = 0;
	while (<HIST>) {
		chomp();
		next if /^[\#\s]/;
		my @record = split /\|/;
		my $timeadded = $record[4];
		if ( $timeadded >= $trim_limit ) {
			print NEWHIST "$_\n";
		} else {
			$deleted_count++;
		}
	}
	close HIST;
	close NEWHIST;
	if ( ! copy($historyfile, $oldhistoryfile) ) {
		die "ERROR: Cannot copy $historyfile to $oldhistoryfile: $!\n";
	}
	if ( ! move($newhistoryfile, $historyfile) ) {
		die "ERROR: Cannot move $newhistoryfile to $historyfile: $!\n";
	}
	main::logger "INFO: Deleted $deleted_count entries from download history\n";
}

# Uses global @history_format
# Adds prog to history file (with a timestamp) so that it is not rerecorded after deletion
sub add {
	my $hist = shift;
	my $prog = shift;

	# Only add if a pid is specified
	return 0 if ! $prog->{pid};
	# Don't add to history if nowrite is used
	return 0 if $opt->{nowrite};

	# Add to history
	if ( ! open(HIST, ">> $historyfile") ) {
		main::logger "ERROR: Cannot write or append to $historyfile\n";
		exit 11;
	}
	# Update timestamp
	$prog->{timeadded} = time();
	# Write each field into a line in the history file
	print HIST $prog->{$_}.'|' for @history_format;
	print HIST "\n";
	close HIST;

	# (re)load whole hist
	# Would be nicer to just add the entry to the history object but this is safer.
	$hist->load();

	return 0;
}



# Uses global @history_format
# returns, for all the pids in the history file, $history->{pid}->{key} = value
sub load {
	my $hist = shift;

	# Return if force option specified
	return 0 if ( $opt->{force} && ! $opt->{pid} ) || $opt->{nowrite};

	# clear first
	$hist->clear();

	main::logger "INFO: Loading recordings history\n" if $opt->{verbose};
	if ( ! open(HIST, "< $historyfile") ) {
		main::logger "WARNING: Cannot read $historyfile\n\n" if $opt->{verbose} && -f $historyfile;
		return 0;
	}

	# Slow. Needs to be faster
	while (<HIST>) {
		chomp();
		# Ignore comments
		next if /^[\#\s]/;
		# Populate %prog_old from cache
		# Get history line
		my @record = split /\|/;
		my $record_entries;
		# Update fields in %history hash for $pid
		for ( @history_format ) {
			$record_entries->{$_} = ( shift @record ) || '';
			if ( /^filename$/ ) {
				$record_entries->{$_} = main::encode_fs($record_entries->{$_});
			}
		}
		# Create new history entry
		if ( defined $hist->{ $record_entries->{pid} } ) {
			main::logger "WARNING: duplicate pid $record_entries->{pid} in history\n" if $opt->{debug};
			# Append filename and modes
			$hist->{ $record_entries->{pid} }->{mode} .= ','.$record_entries->{mode} if defined $record_entries->{mode};
			$hist->{ $record_entries->{pid} }->{filename} .= ','.$record_entries->{filename} if defined $record_entries->{filename};
			main::logger "DEBUG: Loaded and merged '$record_entries->{pid}' = '$record_entries->{name} - $record_entries->{episode}' from history\n" if $opt->{debug};
		} else {
			# workaround empty names
			#$record_entries->{name} = 'pid:'.$record_entries->{pid} if ! $record_entries->{name};
			$hist->{ $record_entries->{pid} } = History->new();
			$hist->{ $record_entries->{pid} } = $record_entries;
			main::logger "DEBUG: Loaded '$record_entries->{pid}' = '$record_entries->{name} - $record_entries->{episode}' from history\n" if $opt->{debug};
		}
	}
	close (HIST);
	return 0;
}



# Clear the history in %{$hist}
sub clear {
	my $hist = shift;
	# There is probably a faster way
	delete $hist->{$_} for keys %{ $pvr };
	return 0;
}



# Loads hist from file if required
sub conditional_load {
	my $hist = shift;

	# Load if empty
	if ( ! keys %{ $hist } ) {
		main::logger "INFO: Loaded history for first check.\n" if $opt->{verbose};
		$hist->load();
	}
	return 0;
}



# Returns a history pid instance ref
sub get_record {
	my $hist = shift;
	my $pid = shift;
	$hist->conditional_load();
	if ( defined $hist->{$pid} ) {
		return $hist->{$pid};
	}
	return undef;
}



# Returns a list of current history pids
sub get_pids {
	my $hist = shift;
	$hist->conditional_load();
	return keys %{ $hist };
}



# Lists current history items
# Requires a load()
sub list_progs {
	my $hist = shift;
	my $prog = {};
	my ( @search_args ) = ( @_ );

	# Load if empty
	$hist->conditional_load();

	# This is a 'well dirty' hack to allow all the Programme class methods to be used on the history objects
	# Basically involves copying all history objects into prog objects and then calling the required method

	# Sort index by timestamp
	my %index_hist;
	main::sort_index( $hist, \%index_hist, undef, 'timeadded' );

	for my $index ( sort {$a <=> $b} keys %index_hist ) {
		my $record = $index_hist{$index};
		my $progrec;
		if ( not main::is_prog_type( $record->{type} ) ) {
			main::logger "WARNING: Programme type '$record->{type}' does not exist - using generic class\n" if $opt->{debug};
			$progrec = Programme->new();
		} else {
			# instantiate a new Programme object and copy all metadata from this history object into it
			$progrec = main::progclass( $record->{type} )->new();
		}
		for my $key ( keys %{ $record } ) {
			$progrec->{$key} = $record->{$key};
		}
		$prog->{ $progrec->{pid} } = $progrec;
		# CAVEAT: The filename is comma-separated if there is a multimode download. For now just use the first one
		if ( $prog->{ $progrec->{pid} }->{mode} =~ /\w+,\w+/ ) {
			$prog->{ $progrec->{pid} }->{mode} =~ s/,.+$//g;
			$prog->{ $progrec->{pid} }->{filename} =~ s/,.+$//g;
		}
	}

	# Parse remaining args
	my @match_list;
	for ( @search_args ) {
		chomp();

		# If Numerical value < $max_index and the object exists from loaded prog types
		if ( /^[\d]+$/ && $_ <= $max_index ) {
			if ( defined $index_hist{$_} ) {
				main::logger "INFO: Search term '$_' is an Index value\n" if $opt->{verbose};
				push @match_list, $prog->{ $index_hist{$_}->{pid} };
			}

		# If PID then find matching programmes with 'pid:<pid>'
		} elsif ( m{^\s*pid:(.+?)\s*$}i ) {
			if ( defined $prog->{$1} ) {
				main::logger "INFO: Search term '$1' is a pid\n" if $opt->{verbose};
				push @match_list, $prog->{$1};
			} else {
				main::logger "INFO: Search term '$1' is a non-existent pid in the history\n";
			}

		# Else assume this is a programme name regex
		} else {
			main::logger "INFO: Search term '$_' is a substring\n" if $opt->{verbose};
			push @match_list, main::get_regex_matches( $prog, $_ );
		}
	}

	# force skipdeleted if --tagonly is specified
	$opt->{skipdeleted} = 1 if $opt->{tagonly};

	# Prune list of history entries with non-existant media files
	if ( $opt->{skipdeleted} ) {
		my @pruned = ();
		for my $this ( @match_list ) {
			# Skip if no filename in history
			if ( defined $this->{filename} && $this->{filename} ) {
				# Skip if the originally recorded file no longer exists
				if ( ! -f $this->{filename} ) {
					main::logger "DEBUG: Skipping metadata/thumbnail/tagging - file no longer exists: '$this->{filename}'\n" if $opt->{verbose};
				} else {
					push @pruned, $this;
				}
			}
		}
		@match_list = @pruned;
	}

	# De-dup matches and retain order then list matching programmes in history
	main::list_progs( undef, main::make_array_unique_ordered( @match_list ) );

	return 0;
}



# Generic
# Checks history for previous download of this pid
sub check {
	my $hist = shift;
	my $pid = shift;
	my $silent = shift;
	return 0 if ! $pid;

	# Return if force option specified
	return 0 if $opt->{force} || $opt->{nowrite};

	# Load if empty
	$hist->conditional_load();

	if ( defined $hist->{ $pid } ) {
		my ( $name, $episode, $histmode ) = ( $hist->{$pid}->{name}, $hist->{$pid}->{episode}, $hist->{$pid}->{mode} );
		main::logger "DEBUG: Found PID='$pid' with MODE='$histmode' in history\n" if $opt->{debug};
		main::logger "INFO: $name - $episode ($pid) Already in history ($historyfile) - use --force to override\n" if ! $silent;
		return 1;
	}

	main::logger "INFO: Programme not in history\n" if $opt->{verbose} && ! $silent;
	return 0;
}




#################### Programme class ###################

package Programme;

use Encode;
use Env qw[@PATH];
use Fcntl;
use File::Basename;
use File::Copy;
use File::Path;
use File::Spec;
use File::stat;
use HTML::Entities;
use HTTP::Cookies;
use HTTP::Headers;
use IO::Seekable;
use IO::Socket;
use LWP::ConnCache;
use LWP::UserAgent;
use POSIX qw(mkfifo strftime);
use strict;
use Time::Local;
use URI;
use Cwd 'abs_path';

# Class vars
# Global options
my $optref;
my $opt;
# File format
sub file_prefix_format { return '<name> - <episode> <pid> <version>' };
# index min/max
sub index_min { return 0 }
sub index_max { return 9999999 };
# Class cmdline Options
sub opt_format {
	return {
	};
}


# Filter channel names matched with options --refreshexclude/--refreshinclude
sub channels_filtered {
	my $prog = shift;
	my $channel_groups = shift;
	# assume class method call
	(my $prog_type = $prog) =~ s/Programme:://;
	my $exclude_groups = $opt->{'refreshexcludegroups'.$prog_type} || $opt->{'refreshexcludegroups'};
	my $include_groups = $opt->{'refreshincludegroups'.$prog_type} || $opt->{'refreshincludegroups'};
	my %channels;
	my %group_channels;
	# include/exclude matching channels as required
	my $include_regex = '.*';
	my $exclude_regex = '^ROGUEVALUE$';
	# Create a regex from any comma separated values
	$exclude_regex = '('.(join '|', ( split /,/, $opt->{refreshexclude} ) ).')' if $opt->{refreshexclude};
	$include_regex = '('.(join '|', ( split /,/, $opt->{refreshinclude} ) ).')' if $opt->{refreshinclude};
	for my $group ( keys %{$channel_groups} ) {
		my %channel_group = %{$channel_groups->{$group}};
		@channels{ keys %channel_group } = values %channel_group;
		if ( ( $exclude_groups && $exclude_groups !~ /\b$group\b/ ) || ( $include_groups && $include_groups =~ /\b$group\b/ ) ) {
			@group_channels{ keys %channel_group } = values %channel_group;
		}
	}
	my $use_group_channels = scalar keys %group_channels;
	$use_group_channels = 1 if ! $use_group_channels && $exclude_groups;
	for my $channel ( keys %channels ) {
		if ( $use_group_channels ) {
			if ( $exclude_regex ne '^ROGUEVALUE$' && $group_channels{$channel} =~ /$exclude_regex/i ) {
				delete $group_channels{$channel};
			}
			if ( $include_regex ne '.*' && $channels{$channel} =~ /$include_regex/i ) {
				$group_channels{$channel} = $channels{$channel} unless $group_channels{$channel};
			}
		}
		unless ( $channels{$channel} !~ /$exclude_regex/i && $channels{$channel} =~ /$include_regex/i ) {
			delete $channels{$channel};
		}
		if ( $use_group_channels ) {
			delete $channels{$channel} if ( $channels{$channel} && ! $group_channels{$channel} );
			$channels{$channel} = $group_channels{$channel} if ( ! $channels{$channel} && $group_channels{$channel} );
		}
	}
	if ( $opt->{verbose} ) {
		main::logger "INFO: Will refresh channel $_\n" for sort values %channels;
	}
	return \%channels;
}


sub channels {
	return {};
}


sub channels_schedule {
	return {};
}


# Method to return optional list_entry format
sub optional_list_entry_format {
	my $prog = shift;
	return '';
}


# Returns the modes to try for this prog type
sub modelist {
	return '';
}


# Default minimum expected download size for a programme type
sub min_download_size {
	return 1024000;
}


# Default cache expiry in seconds
sub expiry {
	return 14400;
}


# Constructor
# Usage: $prog{$pid} = Programme->new( 'pid' => $pid, 'name' => $name, <and so on> );
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	## Ensure that all instances reference the same class global $optref var
	# $self->{optref} = $Programme::optref;
	# Ensure the subclass $opt var is pointing to the Superclass global optref
	$opt = $Programme::optref;
	bless $self, $type;
}


# Use to bind a new options ref to the class global $optref var
sub add_opt_object {
	my $self = shift;
	$Programme::optref = shift;
}


# $opt->{<option>} access method
sub opt {
	my $self = shift;
	my $optname = shift;
	return $opt->{$optname};

	#return $Programme::optref->{$optname};
	#my $opt = $self->{optref};
	#return $self->{optref}->{$optname};
}


# extract PID from URL if necessary
sub clean_pid {
	my $prog = shift;

	if ( $prog->{pid} =~ m{^http.+\/([pb]0[a-z0-9]{6})\/?.*$} ) {
		$prog->{pid} = $1;
	}
}


# This gets run before the download retry loop if this class type is selected
sub init {
}


# Create dir if it does not exist
sub create_dir {
	my $prog = shift;
	if ( (! -d "$prog->{dir}") && (! $opt->{test}) ) {
		main::logger "INFO: Creating dir '$prog->{dir}'\n" if $opt->{verbose};
		eval { mkpath("$prog->{dir}") };
		if ( $@ ) {
			main::logger "ERROR: Could not create dir '$prog->{dir}': $@";
			exit 1;
		}
	}
}


# Return metadata of the prog
sub get_metadata {
	my $prog = shift;
	my $ua = shift;
	$prog->{modes}->{default} = $prog->modelist();
	if ( keys %{ $prog->{verpids} } == 0 ) {
		if ( $prog->get_verpids( $ua ) ) {
			main::logger "ERROR: Could not get version pid metadata\n" if $opt->{verbose};
			return 1;
		}
	}
	$prog->{versions} = join ',', sort keys %{ $prog->{verpids} };
	return 0;
}


# Return metadata which is generic such as time and date
sub get_metadata_general {
	my $prog = shift;
	my @t;

	# Special case for history mode, use {timeadded} to generate these two fields as this represents the time of recording
	if ( $opt->{history} && $prog->{timeadded} ) {
		@t = localtime( $prog->{timeadded} );

	# Else use current time
	} else {
		@t = localtime();
	}

	#($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
	$prog->{dldate} = sprintf "%02s-%02s-%02s", $t[5] + 1900, $t[4] + 1, $t[3];
	$prog->{dltime} = sprintf "%02s:%02s:%02s", $t[2], $t[1], $t[0];

	return 0;
}


# Displays specified metadata from supplied object
# Usage: $prog->display_metadata( <array of elements to display> )
sub display_metadata {
	my %data = %{$_[0]};
	shift;
	my @keys = @_;
	@keys = keys %data if $#_ < 0;
	my $now = time();
	main::logger "\n";
	for (@keys) {
		# Format timeadded field nicely
		if ( /^timeadded$/ ) {
			if ( $data{$_} ) {
				my @t = gmtime( $now - $data{$_} );
				my $ts = strftime('%Y-%m-%dT%H:%M:%S+00:00', gmtime($data{$_}));
				main::logger sprintf "%-15s %s\n", $_.':', "$t[7] days $t[2] hours ago ($ts)";
			}
		} elsif ( /^expires$/ ) {
			if ( $data{$_} && $data{$_} > $now ) {
				my @t = gmtime( $data{$_} - $now );
				my $years = ($t[5]-70)."y " if ($t[5]-70) > 0;
				my $ts = strftime('%Y-%m-%dT%H:%M:%S+00:00', gmtime($data{$_}));
				main::logger sprintf "%-15s %s\n", $_.':', "in ${years}$t[7] days $t[2] hours ($ts)";
			}
		# Streams data
		} elsif ( /^streams$/ ) {
			# skip these
		# If hash then list keys
		} elsif ( ref$data{$_} eq 'HASH' ) {
			for my $key ( sort keys %{$data{$_}} ) {
				main::logger sprintf "%-15s ", $_.':';
				if ( ref$data{$_}->{$key} ne 'HASH' ) {
					main::logger "$key: $data{$_}->{$key}";
				# This is the same as 'modes' list
				#} else {
				#	main::logger "$key: ".(join ',', sort keys %{ $data{$_}->{$key} } );
				}
				main::logger "\n";
			}
		} elsif ( /^desclong$/ ) {
			# strip line breaks
			if ( $data{$_} ) {
				(my $data_out = $data{$_}) =~ s|[\n\r]| |g;
				main::logger sprintf "%-15s %s\n", $_.':', $data_out;
			}
		# else just print out key value pair
		} else {
			main::logger sprintf "%-15s %s\n", $_.':', $data{$_} if $data{$_};
		}
	}
	main::logger "\n";
	return 0;
}



# Return a list of episode pids from the given contents page/pid
sub get_pids_recursive {
	my $prog = shift;
	return '';
}



# Return hash of version => verpid given a pid
# Also put verpids in $prog->{verpids}->{<version>} = <verpid>
sub get_verpids {
	my $prog = shift;
	$prog->{verpids}->{'default'} = 1;
	return 0;
}



# Download Subtitles, convert to srt(SubRip) format and apply time offset
sub download_subtitles {
	# return failed...
	return 1;
}


sub default_version_list {
	return qw/ default original iplayer technical editorial lengthened shortened podcast opensubtitles other /;
}


# Usage: generate_version_list ($prog)
# Returns sorted array of versions
sub generate_version_list {
	my $prog = shift;

	# Default Order with which to search for programme versions (can be overridden by --versionlist option)
	my @version_search_order = default_version_list();
	if ( $opt->{versionlist} ) {
		@version_search_order = map { /^default$/i ? @version_search_order : $_ } split /,/, $opt->{versionlist};
	} else {
		for my $key ( keys %{$prog->{verpids}} ) {
			next if $key =~ /(audiodescribed|signed)/;
			if ( ! grep /^${key}$/i, @version_search_order ) {
				push @version_search_order, lc($key);
			}
		}
	}

	# check here for no matching verpids for specified version search list???
	my $got = 0;
	my @version_list;
	for my $version ( @version_search_order ) {
		if ( defined $prog->{verpids}->{$version} ) {
			$got++;
			push @version_list, $version;
		}
	}

	if ( $got == 0 ) {
		main::logger "INFO: No versions of this programme were selected (available versions: ".(keys %{ $prog->{verpids} } == 0 ? "none" : join ',', sort keys %{ $prog->{verpids} } ).")\n";
	} else {
		main::logger "INFO: Will search for versions: ".(join ',', @version_list)."\n" if $opt->{verbose};
	}
	return @version_list;
}

sub cmp_modes($$) {
	my ($x, $y) = @_;
	my %ranks = (
		'hd(\d+)' => 100,
		'[^x]sd(\d+)' => 200,
		'xsd(\d+)' => 300,
		'vhigh(\d+)' => 400,
		'[^vx]high(\d+)' => 500,
		'xhigh(\d+)' => 600,
		'[^x]std(\d+)' => 700,
		'xstd(\d+)' => 800,
		'med(\d+)' => 900,
		'low(\d+)' => 1000,
		'subtitles(\d+)' => 1100,
	);
	my %ranks2 = (
		'^daf' => 10000,
		'^dvf' => 20000,
		'^haf' => 40000,
		'^hls' => 50000,
		'^hvf' => 60000,
		'^subtitle' => 70000,
	);
	my ($rank_x, $rank_y);
	for my $k ( keys %ranks ) {
		$rank_x = $ranks{$k} + $1 if $x =~ /$k/;
		$rank_y = $ranks{$k} + $1 if $y =~ /$k/;
	}
	for my $k ( keys %ranks2 ) {
		$rank_x += $ranks2{$k} if $x =~ /$k/;
		$rank_y += $ranks2{$k} if $y =~ /$k/;
	}
	$rank_x <=> $rank_y;
}

# Retry the recording of a programme
# Usage: download_retry_loop ( $prog )
sub download_retry_loop {
	my $prog = shift;
	my $hist = shift;

	# Run the type init
	$prog->init();

	# If already downloaded then return
	return 0 if $hist->check( $prog->{pid} );

	# Skip and warn if there is no pid
	if ( ! $prog->{pid} ) {
		main::logger "ERROR: No PID for index $_ (try using --type option ?)\n";
		return 1;
	}

	# Setup user-agent
	my $ua = main::create_ua( 'desktop' );

	# This pre-gets all the metadata - necessary to avoid get_verpids() below if possible
	$prog->get_metadata_general();
	if ( $prog->get_metadata( $ua ) ) {
		main::logger "ERROR: Could not get programme metadata\n" if $opt->{verbose};
		return 1;
	}

	# Look up version pids for this prog - this does nothing if above get_metadata has alredy completed
	if ( keys %{ $prog->{verpids} } == 0 ) {
		if ( $prog->get_verpids( $ua ) ) {
			main::logger "ERROR: Could not get version pid metadata\n" if $opt->{verbose};
			return 1;
		}
	}

	# Re-check history because get_verpids() can update the pid (e.g. BBC /programmes/ URLs)
	return 0 if ( $hist->check( $prog->{pid} ) );

	# if %{ $prog->{verpids} } is empty then skip this programme recording attempt
	if ( (keys %{ $prog->{verpids} }) == 0 ) {
		main::logger "INFO: No versions exist for this programme\n";
		return 1;
	}


	my @version_search_list = $prog->generate_version_list;
	return 1 if $#version_search_list < 0;

	# Get all possible (or user overridden) modes for this prog recording
	my $modelist = $prog->modelist();
	main::logger "INFO: Mode list: $modelist\n" if $opt->{verbose};

	######## version loop #######
	# Do this for each version tried in this order (if they appeared in the content)
	for my $version ( @version_search_list ) {
		my $retcode = 1;
		main::logger "DEBUG: Trying version '$version'\n" if $opt->{debug};
		if ( $prog->{verpids}->{$version} ) {
			main::logger "INFO: Checking existence of $version version\n";
			$prog->{version} = $version;
			main::logger "INFO: Version = $prog->{version}\n" if $opt->{verbose};

			# Try to get stream data for this version if not already populated
			if ( not defined $prog->{streams}->{$version} ) {
				$prog->{streams}->{$version} = $prog->get_stream_data( $prog->{verpids}->{$version}, undef, $version );
			}

			########## mode loop ########
			# record prog depending on the prog type

			# only use modes that exist
			my @modes;
			my @available_modes = sort keys %{ $prog->{streams}->{$version} };
			for my $modename ( split /,/, $modelist ) {
				# find all numbered modes starting with this modename
				push @modes, sort { $a cmp $b } grep /^$modename(\d+)?$/, @available_modes;
			}

			# Check for no applicable modes - report which ones are available if none are specified
			if ($#modes < 0) {
				my %available_modes_short;
				# Strip the number from the end of the mode name and make a unique array
				for ( @available_modes ) {
					my $modename = $_;
					next if $modename =~ /subtitle/;
					$modename =~ s/\d+$//g;
					$available_modes_short{$modename}++;
				}
				my $msg = "No supported modes";
				if ( $opt->{$prog->{type}."mode"} || $opt->{modes} ) {
					$msg = "No specified modes";
				}
				main::logger "INFO: $msg ".($modelist ? "($modelist) " : "")."available for this programme with version '$version'\n";
				if ( keys %available_modes_short ) {
					main::logger "INFO: Try using --modes=".(join ',', sort Programme::cmp_modes keys %available_modes_short)."\n";
				} else {
					main::logger "INFO: No other modes are available\n";
				}
				next;
			}
			main::logger "INFO: ".join(',', @modes)." modes will be tried for version $version\n";

			# Expand the modes into a loop
			for my $mode ( @modes ) {
				chomp( $mode );
				(my $modeshort = $mode) =~ s/\d+$//g;
				# force regeneration of file name if mode changed
				if ( $prog->{modeshort} ne $modeshort ) {
					undef $prog->{filename};
					main::logger "INFO: Regenerate filename for mode change: $prog->{modeshort} -> $modeshort\n" if ( $prog->{modeshort} && $opt->{verbose} );
				}
				$prog->{mode} = $mode;
				# Keep short mode name for substitutions
				$prog->{modeshort} = $modeshort;

				main::logger "INFO: Trying $mode mode to record $prog->{type}: $prog->{name} - $prog->{episode}\n";

				# try the recording for this mode (rtn==0 -> success, rtn==1 -> next mode, rtn==2 -> next prog)
				$retcode = mode_ver_download_retry_loop( $prog, $hist, $ua, $mode, $version, $prog->{verpids}->{$version} );
				main::logger "DEBUG: mode_ver_download_retry_loop retcode = $retcode\n" if $opt->{debug};

				# quit if successful or skip or stop
				last if ( $retcode == 0 || $retcode == 2 || $retcode == 3 );
			}
		}
		# stop condition
		last if $retcode == 3;
		# Break out of loop if we have a successful recording for this version and mode
		return 0 if not $retcode;
	}

	if (! $opt->{test}) {
		main::logger "ERROR: Failed to record '$prog->{name} - $prog->{episode} ($prog->{pid})'\n";
	}
	return 1;
}



# returns 1 on fail, 0 on success
sub mode_ver_download_retry_loop {
	my ( $prog, $hist, $ua, $mode, $version, $version_pid ) = ( @_ );
	my $retries = $opt->{attempts} || 3;
	my $count = 0;
	my $retcode;

	# Retry loop
	for ($count = 1; $count <= $retries; $count++) {
		main::logger "INFO: Attempt number: $count / $retries\n" if $opt->{verbose};

		$retcode = $prog->download( $ua, $mode, $version, $version_pid );
		main::logger "DEBUG: Record using $mode mode return code: '$retcode'\n" if $opt->{verbose};

		# Exit
		if ( $retcode eq 'abort' ) {
			main::logger "ERROR: aborting get_iplayer\n";
			exit 1;

		# don't try any more prog versions
		} elsif ( $retcode eq 'stop' ) {
			main::logger "INFO: skipping all versions of this programme\n";
			return 3;

		# Try Next prog
		} elsif ( $retcode eq 'skip' ) {
			main::logger "INFO: skipping this programme\n";
			return 2;

		# Try Next mode
		} elsif ( $retcode eq 'next' ) {
			# break out of this retry loop
			main::logger "INFO: skipping $mode mode\n";
			last;

		# Success
		} elsif ( $retcode eq '0' ) {
			my $command = $opt->{"command".$prog->{type}} || $opt->{command};
			# Add to history, tag file, and run post-record command if a stream was written
			main::logger "\n";
			if ( $opt->{thumb} ) {
				$prog->create_dir();
				$prog->download_thumbnail();
			}
			if ( $opt->{metadata} ) {
				$prog->create_dir();
				$prog->create_metadata_file();
			}
			if ( ! $opt->{nowrite} ) {
				$hist->add( $prog );
				$prog->tag_file if ! $opt->{notag} && ! $opt->{raw};
			}
			if ( $command && ! $opt->{nowrite} ) {
				$prog->run_user_command( $command );
			}
			$prog->report() if $opt->{pvr};
			return 0;

		# Retry this mode
		} elsif ( $retcode eq 'retry' && $count < $retries ) {
			main::logger "WARNING: Retry recording for '$prog->{name} - $prog->{episode} ($prog->{pid})'\n";
			# Try to get stream data for this version/mode - retries require new auth data
			$prog->{streams}->{$version} = $prog->get_stream_data( $version_pid, undef, $version );
		}
	}
	return 1;
}



# Send a message to STDOUT so that cron can use this to email
sub report {
	my $prog = shift;
	print STDOUT "New $prog->{type} programme: '$prog->{name} - $prog->{episode}', '$prog->{desc}'\n";
	return 0;
}



# add metadata tags to file
sub tag_file {
	my $prog = shift;
	if ( $opt->{tagonly} ) {
		if ( $opt->{tagonlyfilename} ) {
			$prog->{filename} = $opt->{tagonlyfilename};
			(undef, undef, $prog->{ext}) = fileparse($prog->{filename}, qr/\.[^.]*/);
			$prog->{ext} =~ s/^\.//;
		}
		elsif ( $prog->{filename} =~ /\.EXT$/ ) {
			for my $ext ( 'mp4', 'm4a', 'mp3' ) {
				(my $filename = $prog->{filename}) =~ s/\.EXT$/\.$ext/;
				if ( -f $filename ) {
					$prog->{filename} = $filename;
					$prog->{ext} = $ext;
					last;
				}
			}
		}
		if ( ! -f $prog->{filename} ) {
			main::logger "WARNING: Cannot tag missing file $prog->{filename}\n";
			return;
		}
		main::logger "INFO: Tagging file $prog->{filename}\n";
	}
	# return if file does not exist
	return if ! -f $prog->{filename};
	# download thumbnail if necessary
	if ( -f $prog->{thumbfile} ) {
		main::logger("WARNING: File $prog->{thumbfile} already exists\n\n");
	}
	$prog->download_thumbnail if ( ! -f $prog->{thumbfile} && ! $opt->{noartwork} );
	# tag programme
	Tagger->tag_prog($prog);
	# clean up thumbnail if necessary
	unlink $prog->{thumbfile} if ! $opt->{thumb};
}



# Create a metadata file if required
sub create_metadata_file {
	my $prog = shift;
	my $template;
	my $filename;

	# Generic XML template for all info
	$filename->{generic} = "$prog->{dir}/$prog->{fileprefix}.xml";
	$template->{generic}  = '<?xml version="1.0" encoding="UTF-8" ?>'."\n";
	$template->{generic} .= '<program_meta_data xmlns="http://linuxcentre.net/xmlstuff/get_iplayer" revision="1">'."\n";
	$template->{generic} .= "\t<$_>[$_]</$_>\n" for ( sort keys %{$prog} );
	$template->{generic} .= "</program_meta_data>\n";

	return if ! -d $prog->{dir};
	if ( not defined $template->{ $opt->{metadata} } ) {
		main::logger "WARNING: metadata type '$opt->{metadata}' is not valid - must be one of: ".(join ',', keys %{$template} )."\n";
		return;
	}

	main::logger "INFO: Writing $opt->{metadata} metadata to file '$filename->{ $opt->{metadata} }'\n";

	if ( open(XML, "> $filename->{ $opt->{metadata} }") ) {
		my $text = $prog->substitute( $template->{ $opt->{metadata} }, 3, '\[', '\]' );
		# Strip out unsubstituted tags
		$text =~ s/<.+?>\[.+?\]<.+?>[\s\n\r]*//g;
		print XML $text;
		close XML;
	} else {
		main::logger "WARNING: Couldn't write to metadata file '$filename->{ $opt->{metadata} }'\n";
	}
}



# Usage: print $prog{$pid}->substitute('<name>-<pid>-<episode>', [mode], [begin regex tag], [end regex tag]);
# Return a string with formatting fields substituted for a given pid
# sanitize_mode == 0 then sanitize final string and also sanitize '/' in field values
# sanitize_mode == 1 then sanitize final string but don't sanitize '/' (and '\' on Windows) in field values
# sanitize_mode == 2 then just substitute only
# sanitize_mode == 3 then substitute then use encode entities for fields only
# sanitize_mode == 4 then substitute then escape characters in fields only for use in double-quoted shell text.
#
# Also if it find a HASH type then the $prog->{<version>} element is searched and used
# Likewise, if a ARRAY type is found, elements are joined with commas
sub substitute {
	my ( $self, $string, $sanitize_mode, $tag_begin, $tag_end ) = ( @_ );
	$sanitize_mode = 0 if not defined $sanitize_mode;
	$tag_begin = '\<' if not defined $tag_begin;
	$tag_end = '\>' if not defined $tag_end;
	my $version = $self->{version} || 'unknown';
	my $replace = '';

	# Make 'duration' == 'length' for the selected version
	$self->{duration} = $self->{durations}->{$version} if $self->{durations}->{$version};
	$self->{runtime} = int($self->{duration} / 60);

	# Tokenize and substitute $format
	for my $key ( keys %{$self} ) {

		my $value = $self->{$key};

		# Get version specific value if this key is a hash
		if ( ref$value eq 'HASH' ) {
			if ( ref$value->{$version} ne 'HASH' ) {
				$value = $value->{$version};
			} else {
				$value = 'unprintable';
			}
		}

		# Join array elements if value is ARRAY type
		if ( ref$value eq 'ARRAY' ) {
			$value = join ',', @{ $value };
		}

		$value = '' if not defined $value;
		main::logger "DEBUG: Substitute ($version): '$key' => '$value'\n" if $opt->{debug};
		# Remove/replace all non-nice-filename chars if required
		# Keep '/' (and '\' on Windows) if $sanitize_mode == 1
		if ($sanitize_mode == 0 || $sanitize_mode == 1) {
			$replace = StringUtils::sanitize_path( $value, $sanitize_mode );
		# html entity encode
		} elsif ($sanitize_mode == 3) {
			$replace = encode_entities( $value, '&<>"\'' );
			if ( $key =~ /^(expires|timeadded)$/ ) {
				$replace = strftime('%Y-%m-%dT%H:%M:%S+00:00', gmtime($replace));
			}
		# escape these chars: ! ` \ "
		} elsif ($sanitize_mode == 4) {
			$replace = $value;
			# Don't escape file paths
			if ( $key !~ /(filename|filepart|thumbfile|^dir)/ ) {
				$replace =~ s/([\!"\\`])/\\$1/g;
			}
		} else {
			$replace = $value;
		}
		# special handling for <episode*>
		$replace = '' if $replace eq '-' && $key =~ /episode/i;
		# look for prefix in tag
		my $pfx_key = $tag_begin.'([^A-Za-z1-9'.$tag_end.']*?)(0*?)'.$key.$tag_end;
		my ($prefix, $pad) = $string =~ m/$pfx_key/;
		if ( $replace =~ m/^\d+$/ && length($pad) > length($replace) ) {
			$replace = substr($pad.$replace, -length($pad))
		}
		$pfx_key = $tag_begin."\Q$prefix$pad\E".$key.$tag_end;
		$prefix = '' if ! $replace;
		$string =~ s|$pfx_key|$prefix$replace|gi;
	}

	if ( $sanitize_mode == 0 || $sanitize_mode == 1 ) {
		# Remove unused tags
		my $key = $tag_begin.'.*?'.$tag_end;
		$string =~ s|$key||mg;
		# Replace whitespace with _ unless --whitespace
		$string =~ s/\s/_/g unless $opt->{whitespace};
	}
	return $string;
}



# Determine the correct filenames for a recording
# Sets the various filenames and creates appropriate directories
# Gets more programme metadata if the prog name does not exist
#
# Uses:
#	$opt->{fileprefix}
#	$opt->{subdir}
#	$opt->{whitespace}
#	$opt->{test}
# Requires:
#	$prog->{dir}
# Sets:
#	$prog->{fileprefix}
#	$prog->{filename}
#	$prog->{filepart}
# Returns 0 on success, 1 on failure (i.e. if the <filename> already exists)
#
sub generate_filenames {
	my ($prog, $ua, $format, $mode, $version) = (@_);

	# Get and set more meta data - Set the %prog values from metadata if they aren't already set (i.e. with --pid option)
	if ( ! $prog->{name} ) {
		if ( $prog->get_metadata( $ua ) ) {
			main::logger "ERROR: Could not get programme metadata\n" if $opt->{verbose};
			return 1;
		}
		$prog->get_metadata_general();
	}

	# Determine directory and find its absolute path
	$prog->{dir} = File::Spec->rel2abs( $opt->{ 'output'.$prog->{type} } || $opt->{output} || $ENV{IPLAYER_OUTDIR} || '.' );
	$prog->{dir} = main::encode_fs($prog->{dir});

	$prog->{fileprefix} = $opt->{fileprefix} || $format;

	# get $name, $episode from title
	my ( $name, $episode ) = Programme::bbciplayer::split_title( $prog->{title} ) if $prog->{title};
	$prog->{name} = $name if $name && ! $prog->{name};
	$prog->{episode} = $episode if $episode && ! $prog->{episode};

	# store the name extracted from the title metadata in <longname> else just use the <name> field
	$prog->{longname} = $prog->{name} || $name;

	# Set some common metadata fallbacks
	$prog->{nameshort} = $prog->{name} if ! $prog->{nameshort};
	$prog->{episodeshort} = $prog->{episode} if ! $prog->{episodeshort};

	# Create descmedium, descshort by truncation of desc if they don't already exist
	$prog->{desclong} = $prog->{desc} if ! $prog->{desclong};
	$prog->{descmedium} = substr( $prog->{desc}, 0, 1024 ) if ! $prog->{descmedium};
	$prog->{descshort} = substr( $prog->{desc}, 0, 255 ) if ! $prog->{descshort};

	# substitute fields and sanitize $prog->{fileprefix}
	main::logger "DEBUG: Substituted '$prog->{fileprefix}' as " if $opt->{debug};
	# Don't allow <mode> in fileprefix as it can break when resumes fallback on differently numbered modes of the same type change for <modeshort>
	$prog->{fileprefix} =~ s/<mode>/<modeshort>/g;
	$prog->{fileprefix} = $prog->substitute( $prog->{fileprefix} );
	$prog->{fileprefix} = main::encode_fs($prog->{fileprefix});

	# Truncate filename to 240 chars (allows for extra stuff to keep it under system 256 limit)
	# limitprefixlength allows this to be shortened
	unless ( $opt->{limitprefixlength} ) {
		$opt->{limitprefixlength} = 240;
	}
	$prog->{fileprefix} = substr( $prog->{fileprefix}, 0, $opt->{limitprefixlength} );

	main::logger "'$prog->{fileprefix}'\n" if $opt->{debug};

	if ( $opt->{tagonly} && $opt->{tagonlyfilename} ) {
		$prog->{filename} = $opt->{tagonlyfilename};
	}
	# Special case for history mode, parse the fileprefix and dir from filename if it is already defined
	if ( ( $opt->{history} || $opt->{tagonly} ) && defined $prog->{filename} && $prog->{filename} ne '' ) {
		( $prog->{fileprefix}, $prog->{dir}, $prog->{ext} ) = fileparse($prog->{filename}, qr/\.[^.]*/);
		# Fix up file path components
		$prog->{ext} =~ s/\.//;
		$prog->{dir} = File::Spec->canonpath($prog->{dir});
		$prog->{filename} = File::Spec->catfile($prog->{dir}, "$prog->{fileprefix}.$prog->{ext}");
	}

	# Don't create subdir if we are only testing recordings
	# Create a subdir for programme sorting option
	elsif ( $opt->{subdir} ) {
		my $subdir = $prog->substitute( $opt->{subdirformat} || '<longname>', 1 );
		$prog->{dir} = File::Spec->catdir($prog->{dir}, $subdir);
		$prog->{dir} = main::encode_fs($prog->{dir});
		main::logger("INFO: Creating subdirectory $prog->{dir} for programme\n") if $opt->{verbose};
	}

	if ( ! $opt->{nowrite} ) {
		main::logger("INFO: File name prefix = $prog->{fileprefix}                 \n");
	}

	# Get extension from streamdata if defined and raw not specified
	$prog->{ext} = $prog->{streams}->{$version}->{$mode}->{ext};
	# Use a dummy file ext if one isn't set - helps with readability of metadata
	$prog->{ext} = 'EXT' if ! $prog->{ext};
	# output files with --raw
	if ( $opt->{raw} && $mode ) {
		if ( $mode =~ /(haf|hvf|hls)/ ) {
			$prog->{ext} = "ts";
		} elsif ( $mode =~ /daf/ ) {
			$prog->{ext} = "raw.m4a";
		} elsif ( $mode =~ /dvf/ ) {
			$prog->{rawaudio} = main::encode_fs(File::Spec->catfile($prog->{dir}, "$prog->{fileprefix}.raw.m4a"));
			$prog->{rawvideo} = main::encode_fs(File::Spec->catfile($prog->{dir}, "$prog->{fileprefix}.raw.m4v"));
		}
	}

	# check if file extension has changed as a result of failed attempt with different mode
	my $ext_changed = 0;
	if ( ! $opt->{history} && defined $prog->{filename} && $prog->{filename} ne '' ) {
		( my $fileprefix, my $dir, my $ext ) = fileparse($prog->{filename}, qr/\.[^.]*/);
		$ext =~ s/\.//;
		$ext_changed = ( defined $ext && $ext ne '' && $ext ne $prog->{ext} );
		main::logger "DEBUG: File ext changed:   $ext -> $prog->{ext}\n" if $ext_changed && $opt->{debug};
	}

	# Don't override the {filename} if it is already set (i.e. for history info)
	$prog->{filename} = File::Spec->catfile($prog->{dir}, "$prog->{fileprefix}.$prog->{ext}") if ( defined $prog->{filename} && $prog->{filename} =~ /\.EXT$/ ) || ! $prog->{filename} || $ext_changed;
	$prog->{filepart} = File::Spec->catfile($prog->{dir}, "$prog->{fileprefix}.partial.$prog->{ext}");
	$prog->{filename} = main::encode_fs($prog->{filename});
	$prog->{filepart} = main::encode_fs($prog->{filepart});

	# overwrite/error if the file already exists and is going to be written to
	my $min_download_size = main::progclass($prog->{type})->min_download_size();
	if (
		( ! $opt->{nowrite} )
		&& ( ! $opt->{metadataonly} )
		&& ( ! $opt->{thumbonly} )
		&& ( ! $opt->{subsonly} )
		&& ( ! $opt->{tagonly} )
	) {
		if ( $opt->{raw} && $mode ) {
			my $media_type = $prog->{type} eq "tv" ? "video" : "audio";
			my $media_raw = $prog->{filename};
			my $audio_raw = $prog->{rawaudio};
			my $video_raw = $prog->{rawvideo};
			if ( $opt->{overwrite} ) {
				# DASH tv output files with --raw
				if ( $mode =~ /dvf/ ) {
					if ( -f $audio_raw ) {
						main::logger "WARNING: Overwriting raw audio file: $audio_raw\n";
					}
					if ( -f $video_raw ) {
	 					main::logger "WARNING: Overwriting raw video file: $video_raw\n";
	 				}
					unlink ( $audio_raw, $video_raw ) unless $opt->{test};
				} else {
					if ( -f $media_raw ) {
						main::logger "WARNING: Overwriting raw $media_type file: $media_raw\n";
					}
					unlink ( $media_raw ) unless $opt->{test};
				}
			} else {
				my $skip;
				# DASH tv output files with --raw
				if ( $mode =~ /dvf/ ) {
					if ( -f $audio_raw ) {
						main::logger "WARNING: Raw audio file already exists: $audio_raw\n";
						$skip = 1;
					}
					if ( -f $video_raw ) {
						main::logger "WARNING: Raw video file already exists: $video_raw\n";
						$skip = 1;
					}
				} elsif ( -f $media_raw ) {
					main::logger "WARNING: Raw $media_type file already exists: $media_raw\n";
					$skip = 1;
				}
				if ( $skip ) {
					main::logger "WARNING: Use --overwrite to replace\n";
					return 3;
				}
			}
		} elsif ( -f $prog->{filename} && stat($prog->{filename})->size > $min_download_size ) {
			if ( $opt->{overwrite} ) {
				main::logger("WARNING: Overwriting file: $prog->{filename}\n");
				unlink $prog->{filename} unless $opt->{test};
			} else {
				main::logger("WARNING: File already exists: $prog->{filename}\n");
				main::logger "WARNING: Use --overwrite to replace\n\n";
				return 3;
			}
		}

	}

	# Determine thumbnail filename
	if ( $prog->{thumbnail} =~ /^http/i ) {
		my $ext;
		$ext = $1 if $prog->{thumbnail} =~ m{\.(\w+)$};
		$ext = $opt->{thumbext} || $ext;
		$prog->{thumbfile} = File::Spec->catfile($prog->{dir}, "$prog->{fileprefix}.${ext}");
		$prog->{thumbfile} = main::encode_fs($prog->{thumbfile});
	}

	main::logger "DEBUG: File prefix:        $prog->{fileprefix}\n" if $opt->{debug};
	main::logger "DEBUG: File ext:           $prog->{ext}\n" if $opt->{debug};
	main::logger "DEBUG: Directory:          $prog->{dir}\n" if $opt->{debug};
	main::logger "DEBUG: Partial Filename:   $prog->{filepart}\n" if $opt->{debug};
	main::logger "DEBUG: Final Filename:     $prog->{filename}\n" if $opt->{debug};
	main::logger "DEBUG: Thumbnail Filename: $prog->{thumbfile}\n" if $opt->{debug};
	main::logger "DEBUG: Raw Mode:           $opt->{raw}\n" if $opt->{debug};

	# Check path length is < 256 chars (Windows only)
	if ( length( $prog->{filepart} ) > 255 && $^O eq "MSWin32" ) {
		main::logger("ERROR: Generated file path is too long, please use --fileprefix, --subdir-format, --subdir and --output options to shorten it to below 256 characters\n");
		main::logger("ERROR: Generated file path: $prog->{filepart}\n\n");
		return 1;
	}
	return 0;
}



# Run a user specified command
# e.g. --command 'echo "<pid> <name> recorded"'
# run_user_command($pid, 'echo "<pid> <name> recorded"');
sub run_user_command {
	my $prog = shift;
	my $command = shift;

	# Substitute the fields for the PID (and sanitize for double-quoted shell use)
	$command = $prog->substitute( $command, 4 );
	$command = main::encode_fs($command);

	# run command
	main::logger "INFO: Running command '$command'\n" if $opt->{verbose};
	my $exit_value = main::run_cmd( 'normal', $command );

	main::logger "ERROR: Command Exit Code: $exit_value\n" if $exit_value;
	main::logger "INFO: Command succeeded\n" if $opt->{verbose} && ! $exit_value;
				return 0;
}



# %type
# Display a line containing programme info (using long, terse, and type options)
sub list_entry {
	my ( $prog, $prefix, $tree, $number_of_types, $episode_count, $episode_width ) = ( @_ );

	my $prog_type = '';
	# Show the type field if >1 type has been specified
	$prog_type = "$prog->{type}, " if $number_of_types > 1;
	my $name;
	# If tree view
	if ( $opt->{tree} ) {
		$prefix = '  '.$prefix;
		$name = '';
	} else {
		$name = "$prog->{name} - ";
	}

	main::logger "\n${prog_type}$prog->{name}\n" if $opt->{tree} && ! $tree;
	# Display based on output options
	if ( $opt->{listformat} ) {
		# Slow. Needs to be faster e.g:
		#main::logger 'ENTRY'."$prog->{index}|$prog->{thumbnail}|$prog->{pid}|$prog->{available}|$prog->{type}|$prog->{name}|$prog->{episode}|$prog->{versions}|$prog->{duration}|$prog->{desc}|$prog->{channel}|$prog->{categories}|$prog->{timeadded}|$prog->{guidance}|$prog->{web}|$prog->{filename}|$prog->{mode}\n";
		main::logger $prefix.$prog->substitute( $opt->{listformat}, 2 )."\n";
	} elsif ( $opt->{series} && $episode_width && $episode_count && ! $opt->{tree} ) {
		main::logger sprintf( "%s%-${episode_width}s %5s %s\n", $prefix, $prog->{name}, "($episode_count)", $prog->{categories} );
	} elsif ( $opt->{long} ) {
		my $now = time();
		my @time = gmtime( $now - $prog->{timeadded} );
		my $expires;
		if ( $prog->{type} =~ /^(tv|radio)$/ ) {
			if ( $prog->{expires} && $prog->{expires} > $now ) {
				my @t = gmtime( $prog->{expires} - $now );
				my $years = ($t[5]-70)." years " if ($t[5]-70) > 0;
				$expires = ", expires in ${years}$t[7] days $t[2] hours";
			}
		}
		main::logger "${prefix}$prog->{index}:\t${prog_type}${name}$prog->{episode}".$prog->optional_list_entry_format.", added $time[7] days $time[2] hours ago${expires} - $prog->{desc}\n";
	} elsif ( $opt->{terse} ) {
		main::logger "${prefix}$prog->{index}:\t${prog_type}${name}$prog->{episode}\n";
	} else {
		main::logger "${prefix}$prog->{index}:\t${prog_type}${name}$prog->{episode}".$prog->optional_list_entry_format."\n";
	}
	return 0;
}


# Get time ago made available (x days y hours ago) from '2008-06-22T05:01:49Z' and specified epoch time
# Or, Get time in epoch from '2008-06-22T05:01:49Z' or '2008-06-22T05:01:49[+-]NN:NN' if no specified epoch time
sub get_time_string {
	$_ = shift;
	my $diff = shift;

	# suppress warnings for > 32-bit dates in obsolete Perl versions
	local $SIG{__WARN__} = sub {
			warn @_ unless $_[0] =~ m(^.* too (?:big|small));
	};
	# extract $year $mon $mday $hour $min $sec $tzhour $tzmin
	my ($year, $mon, $mday, $hour, $min, $sec, $tzhour, $tzmin);
	if ( m{(\d\d\d\d)\-(\d\d)\-(\d\d)T(\d\d):(\d\d):(\d\d)} ) {
		($year, $mon, $mday, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
	} else {
		return '';
	}

	# positive TZ offset
	($tzhour, $tzmin) = ($1, $2) if m{\d\d\d\d\-\d\d\-\d\dT\d\d:\d\d:\d\d\+(\d\d):(\d\d)};
	# negative TZ offset
	($tzhour, $tzmin) = ($1*-1, $2*-1) if m{\d\d\d\d\-\d\d\-\d\dT\d\d:\d\d:\d\d\-(\d\d):(\d\d)};
	# ending in 'Z'
	($tzhour, $tzmin) = (0, 0) if m{\d\d\d\d\-\d\d\-\d\dT\d\d:\d\d:\d\dZ};

	main::logger "DEBUG: $_ = $year, $mon, $mday, $hour, $min, $sec, $tzhour, $tzmin\n" if $opt->{debug};
	# Sanity check date data
	return '' if $year < 1970 || $mon < 1 || $mon > 12 || $mday < 1 || $mday > 31 || $hour < 0 || $hour > 24 || $min < 0 || $min > 59 || $sec < 0 || $sec > 59 || $tzhour < -13 || $tzhour > 13 || $tzmin < -59 || $tzmin > 59;
	# Calculate the seconds difference between epoch_now and epoch_datestring and convert back into array_time
	my $epoch = eval { timegm($sec, $min, $hour, $mday, ($mon-1), ($year-1900), undef, undef, 0) - $tzhour*60*60 - $tzmin*60; };
	# ensure safe 32-bit date if timegm croaks
	if ( $@ ) { $epoch = timegm(0, 0, 0, 1, 0, 138, undef, undef, 0) - $tzhour*60*60 - $tzmin*60; };
	my $rtn;
	if ( $diff ) {
		# Return time ago
		if ( $epoch < $diff ) {
			my @time = gmtime( $diff - $epoch );
			# The time() func gives secs since 1970, gmtime is since 1900
			my $years = $time[5] - 70;
			$rtn = "$years years " if $years;
			$rtn .= "$time[7] days $time[2] hours ago";
			return $rtn;
		# Return time to go
		} elsif ( $epoch > $diff ) {
			my @time = gmtime( $epoch - $diff );
			my $years = $time[5] - 70;
			$rtn = 'in ';
			$rtn .= "$years years " if $years;
			$rtn .= "$time[7] days $time[2] hours";
			return $rtn;
		# Return 'Now'
		} else {
			return "now";
		}
	# Return time in epoch
	} else {
		# Calculate the seconds difference between epoch_now and epoch_datestring and convert back into array_time
		return $epoch;
	}
}



sub download_thumbnail {
	my $prog = shift;
	my $file;
	my $ext;
	my $image;

	if ( $prog->{thumbnail} =~ /^http/i && $prog->{thumbfile} ) {
		main::logger "INFO: Getting thumbnail from $prog->{thumbnail}\n" if $opt->{verbose};
		$file = $prog->{thumbfile};

		# Download thumb
		$image = main::request_url_retry( main::create_ua( 'desktop', 1 ), $prog->{thumbnail}, 3);
		if (! $image ) {
			main::logger "ERROR: Thumbnail Download failed\n";
			return 1;
		} else {
			main::logger "INFO: Downloaded Thumbnail to '$file'\n" if $opt->{verbose} || $opt->{thumb};
		}

	} else {
		# Return if we have no url
		main::logger "INFO: Thumbnail not available\n" if $opt->{verbose};
		return 2;
	}

	# Write to file
	unlink($file);
	open( my $fh, ">:raw", $file );
	binmode $fh;
	print $fh $image;
	close $fh;

	return 0;
}


################### iPlayer Parent class #################
package Programme::bbciplayer;

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use HTML::Entities;
use HTTP::Cookies;
use HTTP::Headers;
use IO::Seekable;
use IO::Socket;
use LWP::ConnCache;
use LWP::UserAgent;
use POSIX qw(mkfifo);
use Storable qw(dclone);
use strict;
use Time::Local;
use URI;

# Inherit from Programme class
use base 'Programme';


# Return hash of version => verpid given a PID
# and fill in minimal metadata
sub get_verpids {
	my ( $prog, $ua ) = @_;

	my $rc_json = $prog->get_verpids_json( $ua );
	my $rc_html = 1;
	if ( ( ! $prog->{type} || $prog->{type} eq 'tv' ) && ! $opt->{noscrapeversions} ) {
		$rc_html = $prog->get_verpids_html( $ua );
	}
	# ensure title info extracted
	$prog->parse_title();
	return 0 if ! $rc_json || ! $rc_html;
	main::logger "\nWARNING: No programmes are available for this PID with version(s): ".($opt->{versionlist} ? $opt->{versionlist} : 'default').($prog->{versions} ? " (available versions: $prog->{versions})\n" : "\n");
	return 1;
}


# Return hash of version => verpid given a PID
# and fill in minimal metadata
# Uses JSON playlist: http://www.bbc.co.uk/programmes/<pid>/playlist.json
sub get_verpids_json {
	my ( $prog, $ua ) = @_;
	my $pid;
	if ( $prog->{pid} =~ /^http/i ) {
		$pid = $1 if $prog->{pid} =~ /\/([bp]0[a-z0-9]{6})/
	}
	$pid ||= $prog->{pid};
	if ( $prog->{pid} ne $pid ) {
		main::logger "INFO: PID changed from $prog->{pid} to $pid (JSON)\n" if $opt->{verbose};
		$prog->{pid} = $pid;
	}
	if ( $pid !~ /^[bp]0[a-z0-9]{6}$/ ) {
		main::logger "INFO: skipping playlist for non-PID $pid (JSON)\n" if $opt->{verbose};
		return;
	}
	my $url = 'http://www.bbc.co.uk/programmes/'.$pid.'/playlist.json';
	main::logger "INFO: iPlayer metadata URL (JSON) = $url\n" if $opt->{verbose};
	my $json = main::request_url_retry( $ua, $url, 3 );
	if ( ! $json ) {
		main::logger "ERROR: Failed to get version PID metadata from iplayer site (JSON)\n";
		return 1;
	}
	my ( $default, $versions ) = split /"allAvailableVersions"/, $json;
	unless ( $prog->{channel} ) {
		$prog->{channel} = $1 if $default =~ /"masterBrandName":"(.*?)"/;
	}
	unless ( $prog->{descshort} ) {
		$prog->{descshort} = $1 if $default =~ /"summary":"(.*?)"/;
	}
	unless ( $prog->{guidance} ) {
		my $guidance = $2 if $default =~ /"guidance":(null|"(.*?)")/;
		$prog->{guidance} = "Yes" if $guidance;
	}
	unless ( $prog->{thumbnail} ) {
		my $thumbnail = $1 if $default =~ /"holdingImageURL":"(.*?)"/;
		$thumbnail =~ s/\\\//\//g;
		my $thumbsize = $opt->{thumbsize} || $opt->{thumbsizecache} || 150;
		my $recipe = Programme::bbciplayer->thumb_url_recipes->{ $thumbsize };
		if ( ! $recipe ) {
			main::logger "WARNING: Invalid thumbnail size: $thumbsize - using default (JSON)\n";
			$recipe = Programme::bbciplayer->thumb_url_recipes->{ 150 };
		}
		$thumbnail =~ s/\$recipe/$recipe/;
		$prog->{thumbnail} = $thumbnail if $thumbnail;
		$prog->{thumbnail} = "http:".$prog->{thumbnail} unless $prog->{thumbnail} =~ /^http/;
	}
	unless ( $prog->{title} ) {
		my $title = $1 if $default =~ /"title":"(.*?)"/;
		$title =~ s/\\\//\//g;
		$prog->{title} = decode_entities($title) if $title;
	}
	$prog->{type} = 'radio' if $default =~ /"kind":"radioProgramme"/ && $prog->{type} ne 'radio';
	unless ( $prog->{type} ) {
		$prog->{type} = 'tv' if $default =~ /"kind":"programme"/;
	}
	my @versions = split /"markers"/, $versions;
	pop @versions;
	for ( @versions ) {
		main::logger "DEBUG: Block (JSON): $_\n" if $opt->{debug};
		my ($verpid, $version);
		my $type = $1 if /"types":\["(.*?)"/;
		if ( $type =~ /describe/i ) {
			$version = "audiodescribed";
		} elsif ($type =~ /sign/i ) {
			$version = "signed";
		} else {
			($version = lc($type)) =~ s/\s+.*$//;
		}
		next if $prog->{verpids}->{$version};
		$verpid = $1 if /{"vpid":"(\w+)","kind":"(programme|radioProgramme)"/i;
		next if ! ($verpid && $version);
		$prog->{verpids}->{$version} = $verpid;
		$prog->{durations}->{$version} = $1 if /"duration":(\d+)/;
	}
	$prog->{versions} = join ',', keys %{ $prog->{verpids} };
	my $version_map = { "default" => "", "audiodescribed" => "ad", "signed" => "sign"};
	my $version_list = $opt->{versionlist} || $prog->{versions};
	for ( split /,/, $version_list ) {
		if ( $prog->{verpids}->{$_} ) {
			my $episode_url;
			if ( $prog->{type} eq 'tv' ) {
				$episode_url = 'http://www.bbc.co.uk/iplayer/episode/'.$pid."/$version_map->{$_}";
			} elsif ( $prog->{type} eq 'radio' ) {
				$episode_url = 'http://www.bbc.co.uk/programmes/'.$pid;
			}
			unless ( $prog->{player} ) {
				$prog->{player} = $episode_url if $episode_url;
				last;
			}
		}
	}
	my $found;
	for ( keys %{ $prog->{verpids} } ) {
		$found = 1 if $version_list =~ /$_/ && $prog->{verpids}->{$_};
		last if $found;
	}
	return 1 if ! $found;
	return 0;
}


# Return hash of version => verpid given a PID
# and fill in minimal metadata
# Scrapes HTML from episode page: http://www.bbc.co.uk/iplayer/episode/<pid>
# Only works for TV programmes
sub get_verpids_html {
	my ( $prog, $ua ) = @_;
	my $pid;
	if ( $prog->{pid} =~ /^http/i ) {
		$pid = $1 if $prog->{pid} =~ /\/([bp]0[a-z0-9]{6})/
	}
	$pid ||= $prog->{pid};
	if ( $prog->{pid} ne $pid ) {
		main::logger "INFO: PID changed from $prog->{pid} to $pid (HTML)\n" if $opt->{verbose};
		$prog->{pid} = $pid;
	}
	if ( $pid !~ /^[bp]0[a-z0-9]{6}$/ && $pid !~ /^http/ ) {
		main::logger "INFO: skipping playlist for non-PID $pid (HTML)\n" if $opt->{verbose};
		return;
	}
	my $version_list = $opt->{versionlist} || 'default';
	my $version_map = { "default" => "", "audiodescribed" => "ad", "signed" => "sign"};
	for my $version ( "default", "audiodescribed", "signed" ) {
		next if $prog->{verpids}->{$version};
		my $html;
		my $url;
		if ( $pid =~ /^[bp]0[a-z0-9]{6}$/ ) {
			$url = 'http://www.bbc.co.uk/iplayer/episode/'.$pid."/$version_map->{$version}";
		} else {
			$url = $pid;
		}
		main::logger "INFO: iPlayer metadata URL (HTML) [$version] = $url\n" if $opt->{verbose};
		$html = main::request_url_retry( $ua, $url, 3 );
		if ( ! $html ) {
			main::logger "\nINFO: No metadata for $version version retrieved from iPlayer site (HTML)\n" if $opt->{verbose};
			next;
		}
		my $config = $1 if $html =~ /bind\(\{\s*"player":(.*?)\<\/script\>/s;
		unless ($config) {
			$config = $1 if $html =~ /data-playable='(.*?)'/s;
		}
		unless ($config) {
			$config = $1 if $html =~ /data-playable="(.*?)"/s;
			$config =~ s/&quot;/"/g;
		}
		main::logger "DEBUG: Block (HTML): $config\n" if $opt->{debug};
		my $verpid = $1 if $config =~ /"vpid":"(.*?)"/;
		if ( ! $verpid ) {
			$verpid = $1 if $html =~ /data-media-vpid="(.*?)"/;
		}
		if ( ! $verpid ) {
			main::logger "INFO: $version version not found in metadata retrieved from iPlayer site (HTML)\n" if $opt->{verbose};
			next;
		}
		unless ( $prog->{channel} ) {
			$prog->{channel} = $1 if $config =~ /"masterBrandTitle":"(.*?)"/;
		}
		unless ( $prog->{descshort} ) {
			$prog->{descshort} = $1 if $config =~ /"summary":"(.*?)"/;
		}
		unless ( $prog->{guidance} ) {
			my $guidance = $2 if $config =~ /"guidance":(null|"(.*?)")/;
			$prog->{guidance} = "Yes" if $guidance;
		}
		unless ( $prog->{thumbnail} ) {
			my $thumbnail = $1 if $config =~ /"image":"(.*?)"/;
			$thumbnail =~ s/\\\//\//g;
			my $thumbsize = $opt->{thumbsize} || $opt->{thumbsizecache} || 150;
			my $recipe = Programme::bbciplayer->thumb_url_recipes->{ $thumbsize };
			if ( ! $recipe ) {
				main::logger "WARNING: Invalid thumbnail size: $thumbsize - using default (HTML)\n";
				$recipe = Programme::bbciplayer->thumb_url_recipes->{ 150 };
			}
			$thumbnail =~ s/{recipe}/$recipe/;
			$prog->{thumbnail} = $thumbnail if $thumbnail;
			$prog->{thumbnail} = "http:".$prog->{thumbnail} unless $prog->{thumbnail} =~ /^http/;
		}		
		unless ( $prog->{episodenum} ) {
			$prog->{episodenum} = $1 if $config =~ /"parent_position":(\d+)/;
		}		
		unless ( $prog->{title} ) {
			my $title = $1 if $config =~ /"title":"(.*?)"/;
			$title =~ s/\\\//\//g;
			my $subtitle = $1 if $config =~ /"subtitle":"(.*?)"/;
			$subtitle =~ s/\\\//\//g;
			$title .= ": $subtitle" if $subtitle;
			$prog->{title} = decode_entities($title) if $title;
		}
		unless ( $prog->{type} ) {
			$prog->{type} = "tv";
		}
		$prog->{verpids}->{$version} = $verpid;
		$prog->{durations}->{$version} = $1 if $config =~ /"duration":(\d+)/;
	}
	$prog->{versions} = join ',', keys %{ $prog->{verpids} };
	for ( split /,/, $version_list ) {
		if ( $prog->{verpids}->{$_} ) {
			my $episode_url;
			if ( $pid =~ /^[bp]0[a-z0-9]{6}$/ ) {
				if ( $prog->{type} eq 'tv' ) {
					$episode_url = 'http://www.bbc.co.uk/iplayer/episode/'.$pid."/$version_map->{$_}";
				} elsif ( $prog->{type} eq 'radio' ) {
					$episode_url = 'http://www.bbc.co.uk/programmes/'.$pid;
				}
			} elsif ( $pid =~ /^http/ ) {
				$episode_url = $pid;
			}
			unless ( $prog->{player} ) {
				$prog->{player} = $episode_url if $episode_url;
				last;
			}
		}
	}
	my $found;
	for ( keys %{ $prog->{verpids} } ) {
		$found = 1 if $version_list =~ /$_/ && $prog->{verpids}->{$_};
		last if $found;
	}
	return 1 if ! $found;
	return 0;
}

sub parse_title {
	my $prog = shift;
	return unless $prog->{title};
	my ( $name, $episode );
	$prog->{title} =~ s/,\s+(Series.+?),/: $1:/;
	$prog->{title} =~ s/,\s+(Episode.+?)/: $1/;
	$prog->{title} =~ s/^(.+?),\s+(.+)$/$1: $2/ unless $prog->{title} =~ /: Series/;
	$prog->{title} =~ s/^(.+?),\s+(.+)$/$1: $2/ unless $prog->{title} =~ /: Episode/;
	if ( $prog->{title} =~ m{^(.+?Series.*?):\s+(.+?)$} ) {
		( $name, $episode ) = ( $1, $2 );
	} elsif ( $prog->{title} =~ m{^(.+):\s+(.+)$} ) {
		( $name, $episode ) = ( $1, $2 );
	} else {
		( $name, $episode ) = ( $prog->{title}, '-' );
	}
	my ($seriesnum, $episodenum);
	# Extract the seriesnum
	my $regex = 'Series\s+'.main::regex_numbers();
	if ( "$name $episode" =~ m{$regex}i ) {
		$seriesnum = main::convert_words_to_number( $1 );
	}
	# Extract the episode num
	my $regex_1 = 'Episode\s+'.main::regex_numbers();
	my $regex_2 = '^'.main::regex_numbers().'\.\s+';
	if ( "$name $episode" =~ m{$regex_1}i ) {
		$episodenum = main::convert_words_to_number( $1 );
	} elsif ( $episode =~ m{$regex_2}i ) {
		$episodenum = main::convert_words_to_number( $1 );
	}
	# insert episode number in $episode
	$episode = Programme::bbciplayer::insert_episode_number($episode, $episodenum);
	# minimum episode number = 1 if not a film and series number == 0
	$episodenum = 1 if ( $seriesnum == 0 && $episodenum == 0 && $prog->{type} eq 'tv' );
	# minimum series number = 1 if episode number != 0
	$seriesnum = 1 if ( $seriesnum == 0 && $episodenum != 0 );
	$prog->{name} ||= $name;
	$prog->{episode} ||= $episode;
	$prog->{seriesnum} ||= $seriesnum;
	$prog->{episodenum} ||= $episodenum;
}

# get full episode metadata given pid and ua. Uses two different urls to get data
sub get_metadata {
	my $prog = shift;
	my $ua = shift;
	my $prog_data_url = 'http://www.bbc.co.uk/programmes/'; # $pid
	my @ignore_categories = ("Films", "Sign Zone", "Audio Described", "Northern Ireland", "Scotland", "Wales", "England");

	my ($title, $name, $brand, $series, $episode, $longname, $available, $channel, $expires, $meddesc, $longdesc, $summary, $versions, $guidance, $prog_type, $categories, $category, $web, $player, $thumbnail, $seriesnum, $episodenum, $episodepart, $firstbcast );

	# This URL works for tv/radio prog types:
	# http://www.bbc.co.uk/programmes/{pid}.json

	main::logger "DEBUG: Getting metadata for $prog->{pid}:\n" if $opt->{debug};

	my $got_metadata;
	eval "use JSON::PP";
	if ( $@ ) {
		main::logger "WARNING: Please download and run latest installer or install the JSON::PP Perl module for more accurate programme metadata.\n";
	} elsif ( $prog->{pid} =~ /^[bp]0[a-z0-9]{6}$/ ) {
		my $url = $prog_data_url.$prog->{pid}.".json";
		main::logger "INFO: Programme metadata URL = $url\n" if $opt->{verbose};
		my $json = main::request_url_retry($ua, $url, 3, '', '');
		if ( $json ) {
			my $dec =	eval { decode_json($json) };
			if ( ! $@ ) {
				my $doc = $dec->{programme};
				if ( $doc->{type} eq "episode" || $doc->{type} eq "clip" ) {
					my $parent = $doc->{parent}->{programme};
					my $grandparent = $parent->{parent}->{programme};
					my $greatgrandparent = $grandparent->{parent}->{programme};
					my $pid = $doc->{pid};
					my $parentpid = $parent->{pid};
					$prog_type = $doc->{media_type};
					$prog_type = 'tv' if $prog_type =~ m{video}s;
					$prog_type = 'radio' if $prog_type eq 'audio';
					$longdesc = $doc->{long_synopsis};
					$meddesc = $doc->{medium_synopsis};
					$summary = $doc->{short_synopsis};
					$channel = $doc->{ownership}->{service}->{title};
					my $image_pid = $doc->{image}->{pid};
					my $series_image_pid = $doc->{parent}->{programme}->{image}->{pid};
					my $brand_image_pid = $doc->{parent}->{programme}->{parent}->{programme}->{image}->{pid};
					if ( $series_image_pid ) {
						$image_pid = $series_image_pid;
					} elsif ( $brand_image_pid ) {
						$image_pid = $brand_image_pid;
					}
					my $thumbsize = $opt->{thumbsize} || $opt->{thumbsizecache} || 150;
					my $recipe = Programme::bbciplayer->thumb_url_recipes->{ $thumbsize };
					$recipe = Programme::bbciplayer->thumb_url_recipes->{ 150 } if ! $recipe;
					$thumbnail = "http://ichef.bbci.co.uk/images/ic/${recipe}/${image_pid}.jpg";
					$web = "http://www.bbc.co.uk/programmes/$parentpid" if $parentpid;
					if ( $prog_type eq "tv" && $doc->{type} eq "episode" ) {
						$player = "http://www.bbc.co.uk/iplayer/episode/$pid";
					} else {
						$player = "http://www.bbc.co.uk/programmes/$pid";
					}
					# title strings
					my ($series_position, $subseries_position);
					$episode = $doc->{title};
					for my $ancestor ($parent, $grandparent, $greatgrandparent) {
						if ( $ancestor->{type} && $ancestor->{title} ) {
							if ( $ancestor->{type} eq "brand" ) {
								$brand = $ancestor->{title};
							} elsif ( $ancestor->{type} eq "series" ) {
								# handle rare subseries
								if ( $series ) {
									$episode = "$series $episode";
									$subseries_position = $series_position;
								}
								$series = $ancestor->{title};
								$series_position = $ancestor->{position};
							}
						}
					}
					if ( $brand ) {
						if ( $series && $series ne $brand ) {
							$name = "$brand: $series";
						} else {
							$name = $brand;
						}
					} else {
							$name = $series;
					}
					unless ( $name ) {
						$name = $brand = $episode;
						$episode = "-";
						$title = $name;
					} else {
						$title = "$name: $episode";
					}
					# first broadcast date
					$firstbcast = $doc->{first_broadcast_date};
					# categories
					my (@cats1, @cats2, @cats3);
					for my $cat1 ( @{$doc->{categories}} ) {
						unshift @cats1, $cat1->{title};
						my $cat2 = $cat1->{broader}->{category};
						unshift @cats2, $cat2->{title} if $cat2;
						my $cat3 = $cat2->{broader}->{category};
						unshift @cats3, $cat3->{title} if $cat3;
					}
					my %seen;
					my @categories = grep { ! $seen{$_}++ } ( @cats3, @cats2, @cats1 );
					$categories = join(',', @categories);
					foreach my $cat ( @categories ) {
						if ( ! grep(/$cat/i, @ignore_categories) ) {
							$category = $cat;
							last;
						}
					}
					$categories ||= "get_iplayer";
					$category ||= $categories[0] || "get_iplayer";
					# series/episode numbers
					if ( $subseries_position ) {
						my @parts = ("a".."z");
						$episodepart = $parts[$doc->{position} - 1];
					}
					$episodenum = $subseries_position || $doc->{position};
					$seriesnum = $series_position || $parent->{position};
					# the Doctor Who fudge
					my ($seriesnum2, $episodenum2);
					# Extract the seriesnum
					my $regex = 'Series\s+'.main::regex_numbers();
					if ( "$name $episode" =~ m{$regex}i ) {
						$seriesnum2 = main::convert_words_to_number( $1 );
					}
					# Extract the episode num
					my $regex_1 = 'Episode\s+'.main::regex_numbers();
					my $regex_2 = '^'.main::regex_numbers().'\.\s+';
					if ( "$name $episode" =~ m{$regex_1}i ) {
						$episodenum2 = main::convert_words_to_number( $1 );
					} elsif ( $episode =~ m{$regex_2}i ) {
						$episodenum2 = main::convert_words_to_number( $1 );
					}
					# override series/episode numbers if mismatch
					$seriesnum = $seriesnum2 if $seriesnum2;
					$episodenum = $episodenum2 if $episodenum2;
					# insert episode number in $episode
					$episode = Programme::bbciplayer::insert_episode_number($episode, $episodenum, $episodepart);
					# minimum episode number = 1 if not a film and series number == 0
					$episodenum = 1 if ( $seriesnum == 0 && $episodenum == 0 && $prog_type eq 'tv' && $categories !~ "Films" );
					# minimum series number = 1 if episode number != 0
					$seriesnum = 1 if ( $seriesnum == 0 && $episodenum != 0 );
					# programme versions
					my %found;
					for my $ver ( @{$doc->{versions}} ) {
						for my $ver_type ( @{$ver->{types}} ) {
							my $type;
							# check for audiodescribed and signed first
							if ( $ver_type =~ /(described|description)/i ) {
								$type = "audiodescribed";
							} elsif ( $ver_type =~ /sign/i ) {
								$type = "signed";
							} elsif ( $ver_type =~ /open subtitles/i ) {
								$type = "opensubtitles";
							} else {
								($type = lc($ver_type)) =~ s/\s+.*$//;
							}
							if ( $type ) {
								my $version = $type;
								$version .= $found{$type} if ++$found{$type} > 1;
								$prog->{verpids}->{$version} = $ver->{pid};
								$prog->{durations}->{$version} = $ver->{duration};
							}
						}
					}
					$got_metadata = 1 if $pid;
				} else {
					main::logger "WARNING: PID $prog->{pid} does not refer to an iPlayer programme episode or clip. Download may fail and metadata may be inaccurate.\n";
				}
			} else {
				main::logger "WARNING: Could not parse programme metadata from $url ($@)\n";
			}
		} else {
			main::logger "WARNING: Could not download programme metadata from $url\n";
		}
	}

	# Get list of available modes for each version available
	# populate version PIDs and metadata if we don't have them already
	if ( ! $got_metadata || keys %{ $prog->{verpids} } == 0 ) {
		if ( $prog->get_verpids( $ua ) ) {
			main::logger "ERROR: Could not get version PIDs and metadata\n" if $opt->{verbose};
			# Return at this stage unless we want metadata/tags only for various reasons
			return 1 if ! ( $opt->{info} || $opt->{metadataonly} || $opt->{thumbonly} || $opt->{tagonly} )
		}
	}

	# last-chance fallback in case streams found without complete metadata
	$prog->{name} ||= "get_iplayer";
	$prog->{episode} ||= $prog->{pid};
	$prog->{title} ||= "$prog->{name}: $prog->{episode}";

	$prog->{title} 		= $title || $prog->{title};
	$prog->{name} 		= $name || $prog->{name};
	$prog->{episode} 	= $episode || $prog->{episode} || $prog->{name};
	$prog->{brand} 	= $brand || $prog->{name};
	$prog->{series} 	= $series;
	$prog->{type}		= $prog_type || $prog->{type};
	$prog->{channel}	= $channel || $prog->{channel};
	$prog->{expires}	= $expires || $prog->{expires};
	$prog->{guidance}	= $guidance || $prog->{guidance};
	$prog->{categories}	= $categories || $prog->{categories};
	$prog->{category}	= $category || $prog->{category};
	$prog->{desc}		= $summary || $prog->{desc} || $prog->{descshort};
	$prog->{desclong}	= $longdesc || $meddesc || $summary || $prog->{desclong};
	$prog->{descmedium}	= $meddesc || $summary || $prog->{descmedium};
	$prog->{descshort}	= $summary || $prog->{descshort};
	$prog->{player}		= $player || $prog->{player};
	$prog->{web}		= $web || $prog->{web};
	$prog->{thumbnail}	= $thumbnail || $prog->{thumbnail};
	$prog->{episodenum}	= $episodenum || $prog->{episodenum};
	$prog->{episodepart}	= $episodepart || $prog->{episodepart};
	$prog->{seriesnum}	= $seriesnum || $prog->{seriesnum};
	# Conditionally set the senum
	$prog->{senum} = sprintf "s%02se%02s%s", $prog->{seriesnum}, $prog->{episodenum}, $prog->{episodepart} if $prog->{seriesnum} != 0 || $prog->{episodenum} != 0;
	# Create a stripped episode and series with numbers removed + senum s##e## element.
	$prog->{episodeshort} = $prog->{episode};
	$prog->{episodeshort} =~ s/(^|:(\s+))\d+[a-z]?\.\s+/$1/i;
	my $no_number = $prog->{episodeshort};
	$prog->{episodeshort} =~ s/:?\s*Episode\s+.+?(:\s*|$)//i;
	$prog->{episodeshort} =~ s/:?\s*Series\s+.+?(:\s*|$)//i;
	$prog->{episodeshort} = $no_number if $prog->{episodeshort} eq '';
	$prog->{nameshort} = $prog->{brand};
	$prog->{nameshort} =~ s/:?\s*Series\s+\d.*?(:\s*|$)//i;
	$prog->{firstbcast} = $firstbcast;
	$prog->{firstbcastrel} = Programme::get_time_string( $firstbcast, time() );
	($prog->{firstbcastdate} = $firstbcast) =~ s/T.*$//;

	my $modes;
	my $mode_sizes;
	my $first_broadcast;
	my $last_broadcast;
	# Do this for each version tried in this order (if they appeared in the content)
	for my $version ( sort keys %{ $prog->{verpids} } ) {
		# Try to get stream data for this version if it isn't already populated
		if ( not defined $prog->{streams}->{$version} ) {
			# Add streamdata to object
			$prog->{streams}->{$version} = get_stream_data($prog, $prog->{verpids}->{$version}, undef, $version );
		}
		if ( keys %{ $prog->{streams}->{$version} } == 0 ) {
			main::logger "INFO: No streams available for '$version' version ($prog->{verpids}->{$version}) - skipping\n" if $opt->{verbose};
			next;
		}
		$modes->{$version} = join ',', sort Programme::cmp_modes keys %{ $prog->{streams}->{$version} };
		# Estimate the file sizes for each mode
		my @sizes;
		for my $mode ( sort Programme::cmp_modes keys %{ $prog->{streams}->{$version} } ) {
			# get expiry from stream data
			if ( ! $prog->{expires} && $prog->{streams}->{$version}->{$mode}->{expires} ) {
				$prog->{expires} = Programme::get_time_string( $prog->{streams}->{$version}->{$mode}->{expires} );
			}
			my $size;
			if ( $prog->{streams}->{$version}->{$mode}->{size} ) {
				$size = $prog->{streams}->{$version}->{$mode}->{size};
			} else {
				next if ( ! $prog->{durations}->{$version} ) || (! $prog->{streams}->{$version}->{$mode}->{bitrate} );
				$size = $prog->{streams}->{$version}->{$mode}->{bitrate} * $prog->{durations}->{$version} / 8.0 * 1000.0;
			}
			if ( $size < 1048576 ) {
				push @sizes, sprintf( "%s=%.0fKiB", $mode, $size / 1024.0 );
			} else {
				push @sizes, sprintf( "%s=%.0fMiB", $mode, $size / 1048576.0 );
			}
		}
		$mode_sizes->{$version} = join ',', sort Programme::cmp_modes @sizes;
		# Set duration for this version if it is not defined
		$prog->{durations}->{$version} = $prog->{duration} if $prog->{duration} =~ /\d+/ && ! $prog->{durations}->{$version};
	}
	$prog->{modes}		= $modes;
	$prog->{modesizes}	= $mode_sizes;

	my @fields1 = qw(verpids streams durations);

	# remove versions with no streams
	for my $version ( sort keys %{ $prog->{verpids} } ) {
		if ( ! $modes->{$version} || $modes->{$version} =~ /^subtitles\d+$/ ) {
			main::logger "INFO: No streams available for '$version' version ($prog->{verpids}->{$version}) - deleting\n" if $opt->{verbose};
			delete $modes->{$version};
			delete $mode_sizes->{$version};
			for my $key ( @fields1 ) {
				delete $prog->{$key}->{$version};
			}
		}
	}

	# collapse alternate versions with same base name
	for my $version ( sort keys %{ $prog->{verpids} } ) {
		next if $version !~ /\d+$/;
		next if ! $modes->{$version};
		(my $base_version = $version) =~ s/\d+$//;
		if ( ! $modes->{$base_version} || $prog->{durations}->{$base_version} < $prog->{durations}->{$version} ) {
			main::logger "INFO: Using '$version' version ($prog->{verpids}->{$version}) as '$base_version'\n" if $opt->{verbose};
			$modes->{$base_version} = $modes->{$version};
			$mode_sizes->{$base_version} = $mode_sizes->{$version};
			for my $key ( @fields1 ) {
				$prog->{$key}->{$base_version} = $prog->{$key}->{$version};
			}
			delete $modes->{$version};
			delete $mode_sizes->{$version};
			for my $key ( @fields1 ) {
				delete $prog->{$key}->{$version};
			}
		}
	}

	# check at least one version available
	if ( keys %{ $prog->{verpids} } == 0 ) {
		main::logger "WARNING: No media streams found for requested programme versions and recording modes.\n";
		if ( $prog->{geoblocked} ) {
			main::logger "WARNING: The BBC has blocked access to this programme because it has determined that you are using get_iplayer outside the UK.\n";
		}
		# Return at this stage unless we want metadata/tags only for various reasons
		return 1 if ! ( $opt->{info} || $opt->{metadataonly} || $opt->{thumbonly} || $opt->{tagonly} )
	}

	$versions = join ',', sort keys %{ $prog->{verpids} };
	$prog->{versions}	= $versions;

	return 0;
}

sub fetch_pid_type {
	my $ua = shift;
	my $pid = shift;
	my $url = "http://www.bbc.co.uk/programmes/$pid.json";
	my $pid_type;
	eval "use JSON::PP";
	if ( $@ ) {
		main::logger "WARNING: Please download and run latest installer or install the JSON::PP Perl module for more accurate programme metadata.\n";
		return undef;
	}
	my $json = main::request_url_retry($ua, $url, 3, '', '');
	if ( $json ) {
		my $dec =	eval { decode_json($json) };
		if ( ! $@ ) {
			my $doc = $dec->{programme};
			$pid_type = $doc->{type};
		}
	}
	return $pid_type;
}

sub fetch_episode_pids {
	my $ua = shift;
	my $parent_pid = shift;
	my @pids = ();
	my %seen;
	my $max_page = 1;
	my $curr_page = 1;
	eval "use XML::LibXML '1.70'";
	if ( $@ ) {
		main::logger "WARNING: Please download and run latest installer or install the XML::LibXML Perl module to recursively extract episode PIDs.\n";
		return \@pids;
	}
	{ do {
		my $url = "http://www.bbc.co.uk/programmes/$parent_pid/episodes/player?page=$curr_page";
		my $html = main::request_url_retry($ua, $url, 3, '', '');
		last unless $html;
		my $dom = XML::LibXML->load_html(string => $html, recover => 1, suppress_errors => 1);
		my $last_page = $dom->findvalue('//li[contains(@class,"pagination__page--last")]/*/text()');
		$max_page = $last_page if $last_page > $max_page;
		unless ( $seen{'title'} ) {
			my $title = $dom->findvalue('//title');
			$title =~ s/(^\s+|\s+$)//g;
			main::logger "INFO: $title\n";
			$seen{'title'} = 1;
		}
		main::logger "INFO: Page $curr_page of $max_page\n";
		my @episodes = $dom->findnodes('//div[contains(@typeof,"Episode")]');
		for my $episode ( @episodes ) {
			my $pid = $episode->findvalue('@data-pid');
			next if ( $seen{$pid} );
			$seen{$pid} = 1;
			my $name = $episode->findvalue('.//span[contains(@class,"programme__title")]/span/text()');
			my $name2 = $episode->findvalue('.//span[contains(@class,"programme__subtitle")]/span/span/text()');
			$name = "$name2, $name" if $name2;
			main::logger "INFO:     $name ($pid)\n";
			push @pids, $pid;
		}
		$curr_page++;
	} while ( $curr_page <= $max_page ) };
	if ( ! @pids ) {
		main::logger "INFO: No episode PIDs found, checking alternate location...\n";
		$seen{'title'} = 0;
		$max_page = 1;
		$curr_page = 1;
		{ do {
			my $url = "http://www.bbc.co.uk/iplayer/episodes/$parent_pid?page=$curr_page";
			my $html = main::request_url_retry($ua, $url, 3, '', '');
			last unless $html;
			my $dom = XML::LibXML->load_html(string => $html, recover => 1, suppress_errors => 1);
			my $last_page = $dom->findvalue('//div[@class="paginate"]//li[@class="page"][last()]/a/text()');
			$max_page = $last_page if $last_page > $max_page;
			unless ( $seen{'title'} ) {
				my $title = $dom->findvalue('//title');
				$title =~ s/(^\s+|\s+$)//g;
				main::logger "INFO: $title\n";
				$seen{'title'} = 1;
			}
			main::logger "INFO: Page $curr_page of $max_page\n";
			my @episodes = $dom->findnodes('//ul[contains(@class, "iplayer-list")]/li[contains(@class,"episode")]');
			for my $episode ( @episodes ) {
				my $pid = $episode->findvalue('@data-ip-id');
				next if ( $seen{$pid} );
				$seen{$pid} = 1;
				my $name = $episode->findvalue('.//div[@class="secondary"]/div[@class="subtitle"]/text()');
				main::logger "INFO:     $name ($pid)\n";
				push @pids, $pid;
			}
			$curr_page++;
		} while ( $curr_page <= $max_page ) };
 	}
	main::logger "INFO: No episode PIDs found for parent PID: $parent_pid\n" unless @pids;
	return \@pids;
}

sub get_pids_recursive {
	my $prog = shift;
	my $ua = main::create_ua( 'desktop' );
	my @pids = ();

	# Clean up the pid
	main::logger "Cleaning pid Old: '$prog->{pid}', " if $opt->{verbose};
	$prog->clean_pid();
	main::logger " New: '$prog->{pid}'\n" if $opt->{verbose};
	if ( $prog->{pid} !~ m{^([pb]0[a-z0-9]{6})$} ) {
		main::logger "ERROR: Could not extract a valid PID from $prog->{pid}\n";
		return ();
	}

	if ( $opt->{ybbcy} ) {
		my $pid_type = fetch_pid_type( $ua, $prog->{pid} );
		if ( ! $pid_type ) {
			main::logger "WARNING: Could not determine PID type. Trying to record PID directly.\n";
			return $prog->{pid};
		} elsif ( $pid_type eq "episode" ) {
			main::logger "INFO: Episode PID detected\n";
			push @pids, $prog->{pid};
		} elsif ( $pid_type eq "clip" ) {
			main::logger "INFO: Clip PID detected\n";
			push @pids, $prog->{pid};
		} elsif ( $pid_type eq "series" || $pid_type eq "brand" ) {
			main::logger "INFO: Series or Brand PID detected\n";
			my $epids = fetch_episode_pids($ua, $prog->{pid});
			push @pids, @$epids;
			if ( ! $opt->{pidrecursive} ) {
				main::logger "INFO: Please run the command again using one of the above episode PIDs or to get all programmes add the --pid-recursive option\n";
				return ();
			}
		} else {
			main::logger "WARNING: Unknown PID type: $pid_type. Trying to record PID directly.\n";
			return $prog->{pid};
		}
		@pids = main::make_array_unique_ordered( @pids );
		return @pids;
	}
exit;
	eval "use XML::Simple";
	if ($@) {
		main::logger "WARNING: Please download and run latest installer or install the XML::Simple Perl module to use the Series and Brand parsing functionality\n";
		push @pids, $prog->{pid};
	} else {
		#use Data::Dumper qw(Dumper);
		my $rdf = get_rdf_data( $ua, $prog->{pid} );
		if ( ! $rdf ) {
			main::logger "WARNING: PID URL contained no RDF data. Trying to record PID directly.\n";
			return $prog->{pid};
		}
		# an episode-only pid page
		if ( $rdf->{'po:Episode'} ) {
			main::logger "INFO: Episode-only pid detected\n";
			# No need to lookup - we already are an episode pid
			push @pids, $prog->{pid};
		} elsif ( $rdf->{'po:Clip'} ) {
			main::logger "INFO: Clip-only pid detected\n";
			# No need to lookup - we already are a clip pid
			push @pids, $prog->{pid};
		# a series pid page
		} elsif ( $rdf->{'po:Series'} ) {
			main::logger "INFO: Series pid detected\n";
			push @pids, parse_rdf_series( $ua, $prog->{pid} );
			if ( ! $opt->{pidrecursive} ) {
				main::logger "INFO: Please run the command again using one of the above episode PIDs or to get all programmes add the --pid-recursive option\n";
				return ();
			}
		# a brand pid page
		} elsif ( $rdf->{'po:Brand'} ) {
			main::logger "INFO: Brand pid detected\n";
			push @pids, parse_rdf_brand( $ua, $prog->{pid} );
			if ( ! $opt->{pidrecursive} ) {
				main::logger "INFO: Please run the command again using one of the above episode PIDs or to get all programmes add the --pid-recursive option\n";
				return ();
			}
		}
	}
	# now make list unique
	@pids = main::make_array_unique_ordered( @pids );
	return @pids;
}

sub ensure_array {
	my ($in) = @_;
	return defined $in ? ref $in eq 'ARRAY' ? @$in : $in : ();
}

# Gets the episode data from a given episode pid
sub parse_rdf_episode {
	my $ua = shift;
	my $uri = shift;
	my $rdf = get_rdf_data( $ua, $uri );
	if ( ! $rdf ) {
		main::logger "WARNING: Episode PID rdf URL contained no RDF data.\n";
		return '';
	}
	my $pid = extract_pid( $uri );
	main::logger "INFO:      Episode '".$rdf->{'po:Episode'}->{'dc:title'}."' ($pid)\n";
	# We don't really need the ver pids from here
	if ( ref$rdf->{'po:Episode'}->{'po:version'} eq 'ARRAY' ) {
		for my $verpid_element ( @{ $rdf->{'po:Episode'}->{'po:version'} } ) {
			main::logger "INFO:        With Version PID '".extract_pid( $verpid_element->{'rdf:resource'} )."'\n" if $opt->{debug};
		}
	} else {
		main::logger "INFO:        With Version PID '".extract_pid( $rdf->{'po:Episode'}->{'po:version'}->{'rdf:resource'} )."'\n" if $opt->{debug};
	}
	main::logger "INFO:        From Series PID '".extract_pid( $rdf->{'po:Series'}->{'rdf:about'} )."'\n" if $opt->{debug};
	main::logger "INFO:        From Brand PID '".extract_pid( $rdf->{'po:Brand'}->{'rdf:about'} )."'\n" if $opt->{debug};
}



sub parse_rdf_series {
	my $ua = shift;
	my $uri = shift;
	my $rdf = get_rdf_data( $ua, $uri );
	if ( ! $rdf ) {
		main::logger "WARNING: Series PID rdf URL contained no RDF data.\n";
		return '';
	}
	my @pids = ();
	my ($series) = ensure_array($rdf->{'po:Series'});
	my $spid = extract_pid( $series->{'rdf:about'} );
	main::logger "INFO:    Series: '".$series->{'dc:title'}."' ($spid)\n";
	main::logger "INFO:      From Brand PID '".$rdf->{'po:Brand'}->{'rdf:about'}."'\n" if $opt->{debug};
	for my $episode_element (ensure_array($series->{'po:episode'})) {
		my $pid = extract_pid( $episode_element->{'po:Episode'}->{'rdf:about'} );
		main::logger "INFO:      Episode '".$episode_element->{'po:Episode'}->{'dc:title'}."' ($pid)\n";
		push @pids, $pid;
		#parse_rdf_episode( $ua, $pid );
	}
	return @pids;
}



sub parse_rdf_brand {
	my $ua = shift;
	my $uri = shift;
	my $rdf = get_rdf_data( $ua, $uri );
	if ( ! $rdf ) {
		main::logger "WARNING: Brand PID rdf URL contained no RDF data.\n";
		return '';
	}
	my @pids = ();
	my $bpid = extract_pid( $uri );
	main::logger "INFO:  Brand: '".$rdf->{'po:Brand'}->{'dc:title'}."' ($bpid)\n";
	for my $series_element ( ensure_array($rdf->{'po:Brand'}->{'po:series'}) ) {
		main::logger "INFO: With Series pid '".$series_element->{'rdf:resource'}."'\n" if $opt->{debug};
		push @pids, parse_rdf_series( $ua, $series_element->{'rdf:resource'} );
	}
	my @episodes = ensure_array($rdf->{'po:Brand'}->{'po:episode'});
	main::logger "INFO:    Series: <None>\n" if @episodes;
	for my $episode_element ( @episodes ) {
		main::logger "INFO:      Episode pid: ".$episode_element->{'rdf:resource'}."\n" if $opt->{debug};
		push @pids, extract_pid( $episode_element->{'rdf:resource'} );
		parse_rdf_episode( $ua, $episode_element->{'rdf:resource'} );
	}
	return @pids;
}



# Extracts and returns a pid from a URI/URL
sub extract_pid {
	return $1 if $_[0] =~ m{/?([wpb]0[a-z0-9]{6})};
	return '';
}



# Given a pid, gets the rdf URL and returns an XML::Simple object
sub get_rdf_data {
	eval "use XML::Simple";
	if ($@) {
		main::logger "WARNING: Please download and run latest installer or install the XML::Simple Perl module to use the Series and Brand parsing functionality\n";
		return;
	}
	#use Data::Dumper qw(Dumper);
	my $ua = shift;
	my $uri = shift;
	my $pid = extract_pid( $uri );
	my $entry = main::request_url_retry($ua, 'http://www.bbc.co.uk/programmes/'.$pid.'.rdf', 3, '', '');
	if ( ! $entry ) {
		main::logger "WARNING: rdf URL contained no data\n";
		return '';
	}
	# Flatten
	$entry =~ s|[\n\r]| |g;
	my $simple = new XML::Simple();
	my $rdf = $simple->XMLin( $entry );
	#main::logger Dumper ( $rdf )."\n" if $opt->{debug};
	return $rdf;
}



# Intelligently split name and episode from title string for BBC iPlayer metadata
sub split_title {
	my $title = shift;
	my ( $name, $episode );
	# <title type="text">The Sarah Jane Adventures: Series 1: Revenge of the Slitheen: Part 2</title>
	# <title type="text">The Story of Tracy Beaker: Series 4 Compilation: Independence Day/Beaker Witch Project</title>
	# <title type="text">The Sarah Jane Adventures: Series 1: The Lost Boy: Part 2</title>
	if ( $title =~ m{^(.+?Series.*?):\s+(.+?)$} ) {
		( $name, $episode ) = ( $1, $2 );
	} elsif ( $title =~ m{^(.+?):\s+(.+)$} ) {
		( $name, $episode ) = ( $1, $2 );
	# Catch all - i.e. no ':' separators
	} else {
		( $name, $episode ) = ( $title, '-' );
	}
	return ( $name, $episode );
}


sub insert_episode_number {
	my $episode = shift;
	my $episodenum = shift;
	my $episodepart = shift;
	#my $episode_regex = 'Episode\s+'.main::regex_numbers();
	#my $date_regex = '^(\d{2}\/\d{2}\/\d{4}|\d{4}\-\d{2}\-\d{2})';
	if ( $episodenum && $episode !~ /^\d+[a-z]?\./ ) { #&& $episode !~ /$episode_regex/ && $episode !~ /$date_regex/ ) {
		$episode =~ s/^(.*)$/$episodenum$episodepart. $1/;
	}
	return $episode;
}


# Returns hash
sub thumb_url_suffixes {
	return {
		86	=> '_86_48.jpg',
		150	=> '_150_84.jpg',
		178	=> '_178_100.jpg',
		512	=> '_512_288.jpg',
		528	=> '_528_297.jpg',
		640	=> '_640_360.jpg',
		832	=> '_832_468.jpg',
		1024	=> '_1024_576.jpg',
		1280	=> '_1280_720.jpg',
		1600	=> '_1600_900.jpg',
		1920	=> '_1920_1080.jpg',
		1	=> '_86_48.jpg',
		2	=> '_150_84.jpg',
		3	=> '_178_100.jpg',
		4	=> '_512_288.jpg',
		5	=> '_528_297.jpg',
		6	=> '_640_360.jpg',
		7	=> '_832_468.jpg',
		8	=> '_1024_576.jpg',
		9	=> '_1280_720.jpg',
		10	=> '_1600_900.jpg',
		11	=> '_1920_1080.jpg',
	}
}


sub thumb_url_recipes {
	return {
		86	=> '86x48',
		150	=> '150x84',
		178	=> '178x100',
		512	=> '512x288',
		528	=> '528x297',
		640	=> '640x360',
		832	=> '832x468',
		1024	=> '1024x576',
		1280	=> '1280x720',
		1600	=> '1600x900',
		1920	=> '1920x1080',
		1	=> '86x48',
		2	=> '150x84',
		3	=> '178x100',
		4	=> '512x288',
		5	=> '528x297',
		6	=> '640x360',
		7	=> '832x468',
		8	=> '1024x576',
		9	=> '1280x720',
		10	=> '1600x900',
		11	=> '1920x1080',
	}
}


#new_stream_report($mattribs, $cattribs)
sub new_stream_report {
	my $mattribs = shift;
	my $cattribs = shift;

	main::logger "New BBC iPlayer Stream Found:\n";
	main::logger "MEDIA-ELEMENT:\n";

	# list media attribs
	main::logger "MEDIA-ATTRIBS:\n";
	for (keys %{ $mattribs }) {
		main::logger "\t$_ => $mattribs->{$_}\n";
	}

	my @conn;
	if ( defined $cattribs ) {
		@conn = ( $cattribs );
	} else {
		@conn = @{ $mattribs->{connections} };
	}
	for my $cattribs ( @conn ) {
		main::logger "\tCONNECTION-ELEMENT:\n";

		# Print attribs
		for (keys %{ $cattribs }) {
			main::logger "\t\t$_ => $cattribs->{$_}\n";
		}
	}
	return 0;
}



sub parse_metadata {
	my @medias;
	my $xml = shift;
	my %elements;

	# Parse all 'media' elements
	my $element = 'media';
	while ( $xml =~ /<$element\s+(.+?)>(.+?)<\/$element>/sg ) {
		my $xml = $2;
		my $mattribs = parse_attributes( $1 );

		# Parse all 'connection' elements
		my $element = 'connection';
		while ( $xml =~ /<$element\s+(.+?)\/>/sg ) {
			# push to data structure
			push @{ $mattribs->{connections} }, parse_attributes( $1 );
		}
		# mediaselector 5 -> 4 compatibility
		for my $cattribs ( @{ $mattribs->{connections} } ) {
			if ( ! $cattribs->{kind} && $cattribs->{supplier} ) {
				$cattribs->{kind} = $cattribs->{supplier};
			}
		}
		push @medias, $mattribs;
	}


	# Parse and dump structure
	if ( $opt->{debug} ) {
		for my $mattribs ( @medias ) {
			main::logger "MEDIA-ELEMENT:\n";

			# list media attribs
			main::logger "MEDIA-ATTRIBS:\n";
			for (keys %{ $mattribs }) {
				main::logger "\t$_ => $mattribs->{$_}\n";
			}

			for my $cattribs ( @{ $mattribs->{connections} } ) {
				main::logger "\tCONNECTION-ELEMENT:\n";

				# Print attribs
				for (keys %{ $cattribs }) {
					main::logger "\t\t$_ => $cattribs->{$_}\n";
				}
			}
		}
	}

	return @medias;
}



sub parse_attributes {
	$_ = shift;
	my $attribs;
	# Parse all attributes
	while ( /([\w]+?)="(.*?)"/sg ) {
		$attribs->{$1} = $2;
	}
	return $attribs;
}


# from https://github.com/osklil/hls-fetch
sub parse_hls_connection {
	my $media = shift;
	my $conn = shift;
	my $min_bitrate = shift;
	my $max_bitrate = shift;
	my $prefix = shift || "hls";
	decode_entities($conn->{href});
	my @hls_medias;
	my $data = main::request_url_retry( main::create_ua( 'desktop' ), $conn->{href}, 3, undef, undef, 1 );
	if ( ! $data ) {
		main::logger "WARNING: No HLS playlist returned ($conn->{href})\n" if $opt->{verbose};
		return;
	}
	my @lines = split(/\r*\n|\r\n*/, $data);
	if ( @lines < 1 || $lines[0] !~ '^#EXTM3U' ) {
		main::logger "WARNING: Invalid HLS playlist, no header ($conn->{href})\n" if $opt->{verbose};
		return;
	}

	my $best_audio;
	if (!grep { /^#EXTINF:/ } @lines) {
		my (@streams, $last_stream);
		foreach my $line (@lines) {
			next if ($line =~ /^#/ && $line !~ /^#EXT/) || $line =~ /^\s*$/;
			if ($line =~ /^#EXT-X-STREAM-INF:(.*)$/) {
				$last_stream = { parse_m3u_attribs($conn->{href}, $1) };
				if ( $last_stream->{RESOLUTION} && $last_stream->{AUDIO} ) {
					$best_audio->{$last_stream->{RESOLUTION}} = $last_stream->{AUDIO};
				}
				push @streams, $last_stream;
			} elsif ($line !~ /^#EXT/) {
				if ( ! defined $last_stream ) {
					main::logger "WARNING: Missing #EXT-X-STREAM-INF for URL: $line ($conn->{href})\n" if $opt->{verbose};
					return;
				}
				$last_stream->{'URL'} = $line;
				$last_stream = undef;
			}
		}
		if ( ! @streams ) {
			main::logger "WARNING: No streams found in HLS playlist ($conn->{href})\n";
			return,
		};

		main::logger "WARNING: non-numeric bandwidth in HLS playlist\n" if grep { $_->{'BANDWIDTH'} =~ /\D/ } @streams;
		for my $stream ( @streams ) {
			next if $stream->{AUDIO} && $best_audio->{$stream->{RESOLUTION}} && $stream->{AUDIO} ne $best_audio->{$stream->{RESOLUTION}};
			my $hls_media = dclone($media);
			delete $hls_media->{fps};
			delete $hls_media->{width};
			delete $hls_media->{height};
			delete $hls_media->{bitrate};
			delete $hls_media->{media_file_size};
			delete $hls_media->{service};
			delete $hls_media->{connections};
			my ($ab, $vb) = ($1, $2) if $stream->{'URL'} =~ /audio.*?=(\d+)-video.*?=(\d+)/;
			if ( $ab && $vb ) {
				$hls_media->{audio_bitrate} = int($ab/1000);
				$hls_media->{video_bitrate} = int($vb/1000);
			}
			$hls_media->{bitrate} = int($stream->{BANDWIDTH}/1000.0);
			next if $min_bitrate && $hls_media->{bitrate} < $min_bitrate;
			next if $max_bitrate && $hls_media->{bitrate} > $max_bitrate;
			if ( $stream->{RESOLUTION} ) {
				($hls_media->{width}, $hls_media->{height}) = split(/x/, $stream->{RESOLUTION});
				$hls_media->{fps} = $stream->{"FRAME-RATE"} || 25;
			}
			$hls_media->{service} = "gip_${prefix}_iplayer_$hls_media->{bitrate}";
			my $hls_conn = dclone($conn);
			my $uri1 = URI->new($hls_conn->{href});
			my $uri2 = URI->new($stream->{URL});
			my $qs1 = $uri1->query;
			my $qs2 = $uri2->query;
			if ( ! $uri2->scheme ) {
				my @segs1 = $uri1->path_segments;
				my @segs2 = $uri2->path_segments;
				pop @segs1;
				push @segs1, @segs2;
				$uri2 = dclone($uri1);
				$uri2->path_segments(@segs1);
			}
			$qs1 .= "&" if $qs1 && $qs2;
			$uri2->query($qs1.$qs2);
			delete $hls_conn->{href};
			$hls_conn->{href} = $uri2->as_string;
			$hls_media->{connections} = [ $hls_conn ];
			push @hls_medias, $hls_media;
		}
	}
	return @hls_medias;
}

# from https://github.com/osklil/hls-fetch
sub parse_m3u_attribs {
	my ($url, $attr_str) = @_;
	my %attr;
	for (my $as = $attr_str; $as ne ''; ) {
		$as =~ s/^?([^=]*)=([^,"]*|"[^"]*")\s*(,\s*|$)// or main::logger "WARNING: Invalid attributes in HLS playlist: $attr_str ($url)\n";
		my ($key, $val) = ($1, $2);
		$val =~ s/^"(.*)"$/$1/;
		$attr{$key} = $val;
	}
	return %attr;
}

sub parse_dash_connection {
	eval "use XML::Simple";
	if ( $@ ) {
		main::logger "WARNING: Please download and run latest installer or install the XML::Simple Perl module for MPEG-DASH streams.\n";
		return;
	}
	my $media = shift;
	my $conn = shift;
	my $min_bitrate = shift;
	my $max_bitrate = shift;
	my $prefix = shift || "dash";
	my $now = time();
	my @dash_medias;
	decode_entities($conn->{href});
	my $xml = main::request_url_retry( main::create_ua( 'desktop' ), $conn->{href}, 3, undef, undef, 1 );
	if ( ! $xml ) {
		main::logger "WARNING: No DASH manifest returned ($conn->{href})\n" if $opt->{verbose};
		return;
	}
	my $doc = eval { XMLin($xml, KeyAttr => [], ForceArray => 1, SuppressEmpty => 1) };
	if ( $@ ) {
		main::logger "WARNING: Could not parse DASH manifest ($conn->{href})\n" if $opt->{verbose};
		return;
	}
	my $mpd_type = $doc->{type};
	$doc->{mediaPresentationDuration} =~ /^(-)?P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:((\d+)(\.(\d+))?)S)?)?$/;
	my $programme_duration = int($5 * 3600 + $6 * 60 + $7);
	my $available_start = Programme::get_time_string($doc->{availabilityStartTime});
	my $period = $doc->{Period}->[0];
	my $baseurl = $doc->{BaseURL}->[0]->{content};
	if ( ! $baseurl ) {
		$baseurl = $period->{BaseURL}->[0];
	}
	my @audio_medias;
	my @video_medias;
	my $template0 = $period->{AdaptationSet}->[0]->{SegmentTemplate}->[0];
	if ( ! $template0 ) {
		$template0 = $period->{AdaptationSet}->[0]->{Representation}->[0]->{SegmentTemplate}->[0];
	}
	my $xinit = $template0->{initialization};
	my $xmedia = $template0->{media};
	my $dash_conn = dclone($conn);
	my $uri0 = URI->new($baseurl);
	my $uri1 = URI->new($dash_conn->{href});
	my $uri2 = URI->new($xinit);
	if ( ! $uri2->scheme ) {
		if ( ! $uri0->scheme ) {
			$uri2 = URI->new_abs( $uri2, URI->new_abs($uri0, $uri1) );
		} else {
			$uri2 = URI->new_abs( $uri2, $uri0 )
		}
	}
	my $qs1 = $uri1->query;
	my $qs2 = $uri2->query;
	$qs1 .= "&" if $qs1 && $qs2;
	$uri2->query($qs1.$qs2);
	my $init_template = $uri2->as_string;
	my $uri3 = URI->new($xmedia);
	if ( ! $uri3->scheme ) {
		if ( ! $uri0->scheme ) {
			$uri3 = URI->new_abs( $uri3, URI->new_abs($uri0, $uri1) );
		} else {
			$uri3 = URI->new_abs( $uri3, $uri0 )
		}
	}
	$qs1 = $uri1->query;
	my $qs3 = $uri3->query;
	$qs1 .= "&" if $qs1 && $qs3;
	$uri3->query($qs1.$qs3);
	my $media_template = $uri3->as_string;
	for my $set ( @{$period->{AdaptationSet}} ) {
		my $content_type = $set->{contentType};
		my $template = $set->{SegmentTemplate}->[0];
		for my $repr ( @{$set->{Representation}} ) {
			my $bitrate = int($repr->{bandwidth}/1000.0);
			next if $min_bitrate && $bitrate < $min_bitrate;
			next if $max_bitrate && $bitrate > $max_bitrate;
			if ( ! $template ) {
				$template = $repr->{SegmentTemplate}->[0];
			}
			my $segment_duration = $template->{duration} / $template->{timescale};
			my $num_segments = int($programme_duration / $segment_duration);
			$num_segments++ if $segment_duration * $num_segments < $programme_duration;
			my $repr_media = {};
			$repr_media->{id} = $repr->{id};
			$repr_media->{content_type} = $content_type;
			$repr_media->{bitrate} = $bitrate;
			$repr_media->{file_size} = int($programme_duration * $repr_media->{bitrate} * 1000.0 / 8.0);
			$repr_media->{num_segments} = $num_segments;
			$repr_media->{segment_duration} = $segment_duration;
			$repr_media->{programme_duration} = $programme_duration;
			$repr_media->{start_time} = $now;
			$repr_media->{service} = "gip_${prefix}_iplayer_$repr_media->{bitrate}";
			$repr_media->{start_number} = $template->{startNumber} || 1;
			$repr_media->{stop_number} = $repr_media->{start_number} + $num_segments - 1;
			$repr_media->{init_template} = $init_template;
			$repr_media->{media_template} = $media_template;
			if ( $content_type eq "video" ) {
				$repr_media->{width} = $repr->{width};
				$repr_media->{height} = $repr->{height};
				$repr_media->{frameRate} = $repr->{frameRate} || $set->{frameRate};
				push @video_medias, $repr_media;
			} else {
				push @audio_medias, $repr_media;
			}
		}
	}
	my @sorted_audio = sort {$a->{bitrate} <=> $b->{bitrate}} @audio_medias;
	my $video_audio = pop @sorted_audio;

	if ( @video_medias ) {
		for my $video_media ( @video_medias ) {
			my $dash_media = dclone($media);
			delete $dash_media->{width};
			delete $dash_media->{height};
			delete $dash_media->{bitrate};
			delete $dash_media->{service};
			delete $dash_media->{media_file_size};
			delete $dash_media->{connections};
			my $dash_conn = dclone($conn);
			delete $dash_conn->{href};
			$dash_media->{playlist_url} = $conn->{href};
			$dash_media->{width} = $video_media->{width};
			$dash_media->{height} = $video_media->{height};
			$dash_media->{bitrate} = $video_media->{bitrate};
			$dash_media->{service} = $video_media->{service};
			$dash_media->{media_file_size} = $video_media->{file_size};
			$dash_media->{fps} = $video_media->{frameRate};
			$dash_media->{video_media} = $video_media;
			$dash_media->{audio_media} = $video_audio;
			($dash_conn->{href} = $video_media->{init_template}) =~ s/\$RepresentationID\$/$video_media->{id}/;
			$dash_media->{connections} = [ $dash_conn ];
			push @dash_medias, $dash_media;
		}
	} else {
		for my $audio_media ( @audio_medias ) {
			my $dash_media = dclone($media);
			delete $dash_media->{bitrate};
			delete $dash_media->{service};
			delete $dash_media->{media_file_size};
			my $dash_conn = dclone($conn);
			delete $dash_conn->{href};
			$dash_media->{playlist_url} = $conn->{href};
			$dash_media->{bitrate} = $audio_media->{bitrate};
			$dash_media->{service} = $audio_media->{service};
			$dash_media->{media_file_size} = $audio_media->{file_size};
			$dash_media->{audio_media} = $audio_media;
			($dash_conn->{href} = $audio_media->{init_template}) =~ s/\$RepresentationID\$/$audio_media->{id}/;
			$dash_media->{connections} = [ $dash_conn ];
			push @dash_medias, $dash_media;
		}
	}
	return @dash_medias;
}

sub get_stream_data_cdn {
	my ( $data, $mattribs, $mode, $streamer, $ext ) = ( @_ );
	my $data_pri = {};

	my $count = 1;
	for my $cattribs ( @{ $mattribs->{connections} } ) {

		# Common attributes
		my $conn = {
			ext			=> $ext,
			streamer	=> $streamer,
			bitrate		=> $mattribs->{bitrate},
			priority	=> $cattribs->{priority},
			expires		=> $mattribs->{expires},
			size		=> $mattribs->{media_file_size},
		};

		# sis/edgesuite/sislive streams
		if ( $cattribs->{kind} eq 'sis' || $cattribs->{kind} eq 'edgesuite' || $cattribs->{kind} eq 'sislive' ) {
			$conn->{streamurl} = $cattribs->{href};

		# http stream
		} elsif ( $mattribs->{kind} eq 'captions' || $cattribs->{kind} eq 'http' || $cattribs->{kind} eq 'https' ) {
			$conn->{streamurl} = $cattribs->{href};

		# hls stream
		} elsif ( $cattribs->{transferFormat} =~ /hls/ ) {
			$conn->{streamurl} = $cattribs->{href};
			$conn->{kind} = $mattribs->{kind};
			if ( $conn->{kind} eq 'video' ) {
				$conn->{audio_bitrate} = $mattribs->{audio_bitrate};
				if ( $mattribs->{bitrate} > 2000 ) {
					$conn->{audio_bitrate} ||= 128;
				} else {
					$conn->{audio_bitrate} ||= 96;
				}
				$conn->{video_bitrate} = $mattribs->{video_bitrate};
				$conn->{video_bitrate} ||= $mattribs->{bitrate} - $conn->{audio_bitrate};
			}

		# dash stream
		} elsif ( $cattribs->{transferFormat} =~ /dash/ ) {
			$conn->{streamurl} = $cattribs->{href};
			$conn->{kind} = $mattribs->{kind};
			$conn->{audio_media} = $mattribs->{audio_media};
			$conn->{video_media} = $mattribs->{video_media};

		# Unknown CDN
		} else {
			new_stream_report($mattribs, $cattribs) if $opt->{verbose};
			next;
		}

		get_stream_set_type( $conn, $mattribs, $cattribs );

		# Find the next free mode name
		while ( defined $data->{$mode.$count} ) {
			$count++;
		}
		# Add to data structure
		$data->{$mode.$count} = $conn;
		$count++;

	}

	# Add to data structure hased by priority
	$count = 1;
	while ( defined $data->{$mode.$count} ) {
		$data_pri->{ $data->{$mode.$count}->{priority} } = $data->{$mode.$count};
		$count++;
	}
	# Sort mode number according to priority
	$count = 1;
	for my $priority ( reverse sort {$a <=> $b} keys %{ $data_pri } ) {
		# Add to data structure hashed by priority
		$data->{$mode.$count} = $data_pri->{ $priority };
		main::logger "DEBUG: Mode $mode$count = priority $priority\n" if $opt->{debug};
		$count++;
	}
}



# Builds connection type string
sub get_stream_set_type {
		my ( $conn, $mattribs, $cattribs ) = ( @_ );
		my @type;
		push @type, "($mattribs->{service})" if $mattribs->{service};
		push @type, "$conn->{streamer}";
		push @type, "$mattribs->{encoding}" if $mattribs->{encoding};
		push @type, "$mattribs->{width}x$mattribs->{height}" if $mattribs->{width} && $mattribs->{height};
		push @type, "$mattribs->{fps}fps" if $mattribs->{fps};
		push @type, "$mattribs->{bitrate}kbps" if $mattribs->{bitrate};
		push @type, "stream";
		push @type, "(CDN: $cattribs->{kind}/$cattribs->{priority})" if $cattribs->{kind} && $cattribs->{priority};
		push @type, "(CDN: $cattribs->{kind})" if $cattribs->{kind} && not defined $cattribs->{priority};
		$conn->{type} = join ' ', @type;
}


sub check_geoblock {
	return shift =~ /geolocation|notukerror/;
}


# Generic
# Gets media streams data for this version pid
# $media = undef|<modename>
sub get_stream_data {
	my ( $prog, $verpid, $media, $version ) = @_;
	my $mode;
	my $modelist = $prog->modelist();
	my $data = {};
	my @media_stream_pc_prefixes;
	my @media_stream_iptv_prefixes;
	my @media_stream_mobile_prefixes;
	my ( @pc_mediasets, @iptv_mediasets, @mobile_mediasets );
	@pc_mediasets = ( 'pc' );
	@iptv_mediasets = ( 'iptv-all' );
	@mobile_mediasets = ( 'apple-ipad-hls' );
	if ( $prog->{type} eq "radio" ) {
		push @mobile_mediasets, 'apple-iphone4-ipad-hls-3g';
	}
	for my $mediaset ( @pc_mediasets ) {
		push @media_stream_pc_prefixes, "http://open.live.bbc.co.uk/mediaselector/5/select/version/2.0/mediaset/$mediaset/vpid/";
	}
	for my $mediaset ( @iptv_mediasets ) {
		push @media_stream_iptv_prefixes, "http://open.live.bbc.co.uk/mediaselector/5/select/version/2.0/mediaset/$mediaset/vpid/";
	}
	for my $mediaset ( @mobile_mediasets ) {
		push @media_stream_mobile_prefixes, "http://open.live.bbc.co.uk/mediaselector/5/select/version/2.0/mediaset/$mediaset/vpid/";
	}

	# filter CDN suppliers
	my @exclude_supplier = split(/,/, $opt->{excludesupplier});
	if ( $opt->{includesupplier} ) {
		@exclude_supplier = grep { $opt->{includesupplier} !~ /\b$_\b/ } @exclude_supplier;
	}
	if ( grep /^akamai/, @exclude_supplier ) {
		push @exclude_supplier, 'ak';
	}
	if ( grep /^limelight/, @exclude_supplier ) {
		push @exclude_supplier, 'll';
	}
	my $exclude_regex = '^ROGUEVALUE$';
	if ( @exclude_supplier ) {
		$exclude_regex = '('.(join('|', @exclude_supplier)).')';
	}

	# Setup user agent with redirection enabled
	my $ua = main::create_ua( 'desktop' );

	# BBC streams
	my $xml;
	my @medias;
	my $unblocked;
	my $checked_geoblock;

	my (%seen, $stream_key);
	if ( $opt->{info} || $modelist =~ /(daf|dvf)/ ) {
		# get MPEG-DASH streams for on-demand
		push @media_stream_pc_prefixes, @media_stream_iptv_prefixes if $prog->{type} eq "tv";
		for my $media_stream_pc_prefix ( @media_stream_pc_prefixes ) {
			$xml = main::request_url_retry( $ua, $media_stream_pc_prefix.$verpid.'/transferformat/dash?cb='.( sprintf "%05.0f", 99999*rand(0) ), 3, undef, undef, 1, 1 );
			main::logger "\n$xml\n" if $opt->{debug};
			$checked_geoblock = 1;
			next if check_geoblock( $xml );
			$unblocked = 1;
			decode_entities($xml);
			my @pc_medias = parse_metadata( $xml );
			for my $pc_media ( @pc_medias ) {
				for my $pc_conn ( @{$pc_media->{connections}} ) {
					next if $pc_conn->{supplier} =~ /$exclude_regex/;
					$stream_key = "$pc_media->{service}-$pc_conn->{protocol}-$pc_conn->{supplier}";
					next if $seen{$stream_key};
					$seen{$stream_key}++;
					($stream_key = $pc_conn->{href}) =~ s/\?.*//;
					next if $seen{$stream_key};
					$seen{$stream_key}++;
					if ( $pc_media->{kind} eq "captions" ) {
						my $media = dclone($pc_media);
						@{$media->{connections}} = ( $pc_conn );
						push @medias, $media;
						next;
					}
					my $prefix = $prog->{type} eq "radio" ? "daf" : "dvf";
					my @dash_medias = parse_dash_connection( $pc_media, $pc_conn, undef, undef, $prefix );
					for my $dash_media ( @dash_medias ) {
						for my $dash_conn ( @{$dash_media->{connections}} ) {
							$stream_key = "$dash_media->{service}-$dash_conn->{protocol}-$dash_conn->{supplier}";
							next if $seen{$stream_key};
							$seen{$stream_key}++;
							($stream_key = $dash_conn->{href}) =~ s/\?.*//;
							next if $seen{$stream_key};
							$seen{$stream_key}++;
							push @medias, $dash_media;
							last;
						}
					}
				}
			}
		}
	}
	if ( $opt->{info} || $modelist =~ /(hls|hvf|haf)/ ) {
		if ( $prog->{type} eq "tv" ) {
			# get HLS streams from IPTV data
			for my $media_stream_iptv_prefix ( @media_stream_iptv_prefixes ) {
				$xml = main::request_url_retry( $ua, $media_stream_iptv_prefix.$verpid.'/transferformat/hls?cb='.( sprintf "%05.0f", 99999*rand(0) ), 3, undef, undef, 1, 1 );
				main::logger "\n$xml\n" if $opt->{debug};
				$checked_geoblock = 1;
				next if check_geoblock( $xml );
				$unblocked = 1;
				decode_entities($xml);
				my @iptv_medias = parse_metadata( $xml );
				for my $iptv_media ( @iptv_medias ) {
					for my $iptv_conn ( @{$iptv_media->{connections}} ) {
						next if $iptv_conn->{supplier} =~ /$exclude_regex/;
						$stream_key = "$iptv_media->{service}-$iptv_conn->{protocol}-$iptv_conn->{supplier}";
						next if $seen{$stream_key};
						$seen{$stream_key}++;
						($stream_key = $iptv_conn->{href}) =~ s/\?.*//;
						next if $seen{$stream_key};
						$seen{$stream_key}++;
						if ( $iptv_media->{kind} eq "captions" ) {
							my $media = dclone($iptv_media);
							@{$media->{connections}} = ( $iptv_conn );
							push @medias, $media;
							next;
						}
						my $prefix = $iptv_conn->{supplier} =~ /hls_open/ ? "hls" : "hvf";
						$iptv_conn->{href} =~ s!([^/]+)\.ism(?:\.hlsv2\.ism)?/[^/]+\.m3u8!$1.ism/$1.m3u8!;
						my ( $min_bitrate, $max_bitrate );
						if ( $prefix eq "hvf" ) {
							$min_bitrate = 1500;
							$max_bitrate = 6500;
						}
						my @hls_medias = parse_hls_connection( $iptv_media, $iptv_conn, $min_bitrate, $max_bitrate, $prefix );
						for my $hls_media ( @hls_medias ) {
							for my $hls_conn ( @{$hls_media->{connections}} ) {
								$stream_key = "$hls_media->{service}-$hls_conn->{protocol}-$hls_conn->{supplier}";
								next if $seen{$stream_key};
								$seen{$stream_key}++;
								($stream_key = $hls_conn->{href}) =~ s/\?.*//;
								next if $seen{$stream_key};
								$seen{$stream_key}++;
								push @medias, $hls_media;
								last;
							}
						}
					}
				}
			}
		}
		# get HLS streams from mobile data
		for my $media_stream_mobile_prefix ( @media_stream_mobile_prefixes ) {
			$xml = main::request_url_retry( $ua, $media_stream_mobile_prefix.$verpid.'/transferformat/hls?cb='.( sprintf "%05.0f", 99999*rand(0) ), 3, undef, undef, 1, 1 );
			main::logger "\n$xml\n" if $opt->{debug};
			$checked_geoblock = 1;
			next if check_geoblock( $xml );
			$unblocked = 1;
			decode_entities($xml);
			my @mobile_medias = parse_metadata( $xml );
			for my $mobile_media ( @mobile_medias ) {
				for my $mobile_conn ( @{$mobile_media->{connections}} ) {
					next if $mobile_conn->{supplier} =~ /$exclude_regex/;
					$stream_key = "$mobile_media->{service}-$mobile_conn->{protocol}-$mobile_conn->{supplier}";
					next if $seen{$stream_key};
					$seen{$stream_key}++;
					($stream_key = $mobile_conn->{href}) =~ s/\?.*//;
					next if $seen{$stream_key};
					$seen{$stream_key}++;
					if ( $mobile_media->{kind} eq "captions" ) {
						my $media = dclone($mobile_media);
						@{$media->{connections}} = ( $mobile_conn );
						push @medias, $media;
						next;
					}
					my $prefix = $prog->{type} eq "radio" ? "haf" : "hvf";
					if ( $mobile_conn->{supplier} =~ /hls_open/ ) {
						if ( $prog->{type} eq 'tv' ) {
							$prefix = "hls";
						} elsif ( $prog->{type} eq 'radio' ) {
							$prefix = "hlsaac";
						}
					}
					if ( $prog->{type} eq 'radio' ) {
						# for HLS 320k and 96k
						$mobile_conn->{href} =~ s!([^/]+)\.ism(?:\.hlsv2\.ism)?/[^/]+\.m3u8!$1.ism/$1.m3u8!;
					}
					my @hls_medias = parse_hls_connection( $mobile_media, $mobile_conn, undef, undef, $prefix );
					for my $hls_media ( @hls_medias ) {
						for my $hls_conn ( @{$hls_media->{connections}} ) {
							$stream_key = "$hls_media->{service}-$hls_conn->{protocol}-$hls_conn->{supplier}";
							next if $seen{$stream_key};
							$seen{$stream_key}++;
							($stream_key = $hls_conn->{href}) =~ s/\?.*//;
							next if $seen{$stream_key};
							$seen{$stream_key}++;
							push @medias, $hls_media;
							last;
						}
					}
				}
			}
		}
	}

	unless ( $unblocked ) {
		$prog->{geoblocked} = 1 if $checked_geoblock;
		return undef;
	}

	# Parse and dump structure
	for my $mattribs ( @medias ) {

		# Put verpid into mattribs
		$mattribs->{verpid} = $verpid;
		$mattribs->{modelist} = $modelist;

		if ( $mattribs->{service} =~ /hls/ ) {
			if ( $mattribs->{kind} =~ 'video' ) {
				my $ext = "mp4";
				if ( $mattribs->{height} > 700 ) {
					get_stream_data_cdn( $data, $mattribs, "hlshd", 'hls', $ext );
				}	elsif ( $mattribs->{height} > 400 ) {
					get_stream_data_cdn( $data, $mattribs, "hlsvhigh", 'hls', $ext );
				} elsif ( $mattribs->{height} > 300 ) {
					if ( $mattribs->{bitrate} > 700 ) {
						get_stream_data_cdn( $data, $mattribs, "hlsstd", 'hls', $ext );
					} elsif ( $mattribs->{bitrate} > 450 ) {
						get_stream_data_cdn( $data, $mattribs, "hlsxstd", 'hls', $ext );
					}
				}
			} elsif ( $mattribs->{kind} =~ 'audio' ) {
				my $ext = "m4a";
				if ( $mattribs->{bitrate} >= 192 ) {
					get_stream_data_cdn( $data, $mattribs, 'hlsaachigh', 'hls', $ext );
				} elsif ( $mattribs->{bitrate} >= 120 ) {
					get_stream_data_cdn( $data, $mattribs, 'hlsaacstd', 'hls', $ext );
				} elsif ( $mattribs->{bitrate} >= 80 ) {
					get_stream_data_cdn( $data, $mattribs, 'hlsaacmed', 'hls', $ext );
				} else {
					get_stream_data_cdn( $data, $mattribs, 'hlsaaclow', 'hls', $ext );
				}
			}

		} elsif ( $mattribs->{service} =~ /hvf/ ) {
			if ( $mattribs->{kind} =~ 'video' ) {
				my $ext = "mp4";
				if ( $mattribs->{height} > 700 ) {
					get_stream_data_cdn( $data, $mattribs, "hvfhd", 'hls', $ext );
				} elsif ( $mattribs->{height} > 500 ) {
					if ( $mattribs->{bitrate} > 2500 ) {
						get_stream_data_cdn( $data, $mattribs, "hvfsd", 'hls', $ext );
					} else {
						get_stream_data_cdn( $data, $mattribs, "hvfxsd", 'hls', $ext );
					}
				} elsif ( $mattribs->{height} > 350 ) {
					if ( $mattribs->{bitrate} > 1500 ) {
						get_stream_data_cdn( $data, $mattribs, "hvfhigh", 'hls', $ext );
					} else {
						get_stream_data_cdn( $data, $mattribs, "hvfxhigh", 'hls', $ext );
					}
				} elsif ( $mattribs->{height} > 250 ) {
					get_stream_data_cdn( $data, $mattribs, "hvflow", 'hls', $ext );
				}
			}

		} elsif ( $mattribs->{service} =~ /haf/ ) {
			if ( $mattribs->{kind} =~ 'audio' ) {
				my $ext = "m4a";
				if ( $mattribs->{bitrate} >= 192 ) {
					get_stream_data_cdn( $data, $mattribs, 'hafhigh', 'hls', $ext );
				} elsif ( $mattribs->{bitrate} >= 120 ) {
					get_stream_data_cdn( $data, $mattribs, 'hafstd', 'hls', $ext );
				} elsif ( $mattribs->{bitrate} >= 80 ) {
					get_stream_data_cdn( $data, $mattribs, 'hafmed', 'hls', $ext );
				} else {
					get_stream_data_cdn( $data, $mattribs, 'haflow', 'hls', $ext );
				}
			}

		} elsif ( $mattribs->{service} =~ /dvf/ ) {
			if ( $mattribs->{kind} =~ 'video' ) {
				my $ext = "mp4";
				if ( $mattribs->{height} > 700 ) {
					get_stream_data_cdn( $data, $mattribs, "dvfhd", 'dash', $ext );
				} elsif ( $mattribs->{height} > 500 ) {
					if ( $mattribs->{bitrate} > 2500 ) {
						get_stream_data_cdn( $data, $mattribs, "dvfsd", 'dash', $ext );
					} else {
						get_stream_data_cdn( $data, $mattribs, "dvfxsd", 'dash', $ext );
					}
				} elsif ( $mattribs->{height} > 350 ) {
					if ( $mattribs->{bitrate} > 1500 ) {
						get_stream_data_cdn( $data, $mattribs, "dvfhigh", 'dash', $ext );
					} else {
						get_stream_data_cdn( $data, $mattribs, "dvfxhigh", 'dash', $ext );
					}
				} elsif ( $mattribs->{height} > 250 ) {
					get_stream_data_cdn( $data, $mattribs, "dvflow", 'dash', $ext );
				}
			}

		} elsif ( $mattribs->{service} =~ /daf/ ) {
			if ( $mattribs->{kind} =~ 'audio' ) {
				my $ext = "m4a";
				# use DASH 320k stream as HLS 320k stream
				if ( $mattribs->{bitrate} >= 192 ) {
					get_stream_data_cdn( $data, $mattribs, "dafhigh", 'dash', $ext );
				} elsif ( $mattribs->{bitrate} >= 120 ) {
					get_stream_data_cdn( $data, $mattribs, "dafstd", 'dash', $ext );
				} elsif ( $mattribs->{bitrate} >= 80 ) {
					get_stream_data_cdn( $data, $mattribs, "dafmed", 'dash', $ext );
				} else {
					get_stream_data_cdn( $data, $mattribs, "daflow", 'dash', $ext );
				}
			}

		# Subtitles modes
		} elsif (	$mattribs->{kind} eq 'captions' &&
				$mattribs->{type} eq 'application/ttaf+xml'
		) {
			get_stream_data_cdn( $data, $mattribs, 'subtitles', 'http', 'srt' );

		# Catch unknown
		} else {
			new_stream_report($mattribs, undef) if $opt->{verbose};
		}
	}

	# Report modes found
	if ( $opt->{verbose} ) {
	main::logger "INFO: Found mode $_: $data->{$_}->{type}\n" for sort Programme::cmp_modes keys %{ $data };
	}

	# Return a hash with media => url if '' is specified - otherwise just the specified url
	if ( ! $media ) {
		return $data;
	} else {
		# Make sure this hash exists before we pass it back...
		$data->{$media}->{exists} = 0 if not defined $data->{$media};
		return $data->{$media};
	}
}

sub modelist {
	my $prog = shift;
	my $mlist = $opt->{$prog->{type}."mode"} || $opt->{modes};
	# Defaults
	if ( ! $mlist ) {
		$mlist = 'default';
	}
	my $mlist_orig = $mlist;
	$mlist =~ s/flashaac/daf/g;
	$mlist =~ s/rtmp/flash/g;
	$mlist =~ s/flash/hls/g;
	if ( $prog->{type} eq "tv" ) {
		# backcompat
		$mlist =~ s/tv25fps/tvdefault/g;
		$mlist =~ s/hlshigh/hlsstd/g;
		$mlist =~ s/hlslow/hlsxstd/g;
		$mlist =~ s/hvfvhigh/hvfxsd/g;
		$mlist =~ s/hvfstd/hvflow/g;
	} elsif ( $prog->{type} eq "radio" ) {
		$mlist =~ s/\bhls\b/hlsaac/g if $mlist !~ /hlsaac/;
		$mlist =~ s/dash/daf/g;
	}
	if ( $mlist ne $mlist_orig && ! $opt->{modewarn} ) {
		main::logger "WARNING: Some recording modes were remapped to new values\n";
		main::logger "WARNING: Input mode list remapped from '$mlist_orig' to '$mlist'\n";
		main::logger "WARNING: Please update your preferences\n";
		$opt->{modewarn} = 1;
	}
	# Deal with fallback modes and expansions
	# Generic aliases
	$mlist = main::expand_list($mlist, 'default', "$prog->{type}default");
	$mlist = main::expand_list($mlist, 'best', "$prog->{type}best");
	$mlist = main::expand_list($mlist, 'better', "$prog->{type}better");
	$mlist = main::expand_list($mlist, 'vgood', "$prog->{type}vgood");
	$mlist = main::expand_list($mlist, 'good', "$prog->{type}good");
	$mlist = main::expand_list($mlist, 'worse', "$prog->{type}worse");
	$mlist = main::expand_list($mlist, 'worst', "$prog->{type}worst");
	# DASH on-demand radio
	if ( $prog->{type} eq "radio" && $mlist =~ /daf/ ) {
		$mlist = main::expand_list($mlist, 'daf', 'dafdefault');
		$mlist = main::expand_list($mlist, 'dafdefault', 'dafbest');
		$mlist = main::expand_list($mlist, 'dafbest', 'dafhigh,dafbetter');
		$mlist = main::expand_list($mlist, 'dafbetter', 'dafvgood');
		$mlist = main::expand_list($mlist, 'dafvgood', 'dafstd,dafgood');
		$mlist = main::expand_list($mlist, 'dafgood', 'dafmed,dafworse');
		$mlist = main::expand_list($mlist, 'dafworse', 'dafworst');
		$mlist = main::expand_list($mlist, 'dafworst', 'daflow');
	}
	# DASH on-demand tv
	if ( $prog->{type} eq "tv" && $mlist =~ /dvf/ ) {
		$mlist = main::expand_list($mlist, 'dvf', 'dvfdefault');
		$mlist = main::expand_list($mlist, 'dvfdefault', 'dvfbest');
		if ( $opt->{fps50} ) {
			$mlist = main::expand_list($mlist, 'dvfbest', 'dvfhd,dvfbetter');
			$mlist = main::expand_list($mlist, 'dvfbetter', 'dvfsd,dvfxsd,dvfvgood');
			$mlist = main::expand_list($mlist, 'dvfvgood', 'dvfgood');
			$mlist = main::expand_list($mlist, 'dvfgood', 'dvfhigh,dvfxhigh,dvfworse');
		} else {
			$mlist = main::expand_list($mlist, 'dvfbest', 'dvfbetter');
			$mlist = main::expand_list($mlist, 'dvfbetter', 'dvfxsd,dvfvgood');
			$mlist = main::expand_list($mlist, 'dvfvgood', 'dvfgood');
			$mlist = main::expand_list($mlist, 'dvfgood', 'dvfxhigh,dvfworse');
		}
		$mlist = main::expand_list($mlist, 'dvfworse', 'dvfworst');
		$mlist = main::expand_list($mlist, 'dvfworst', 'dvflow');
	}
	# HLS Audio Factory on-demand radio
	if ( $prog->{type} eq "radio" && $mlist =~ /haf/ ) {
		$mlist = main::expand_list($mlist, 'haf', 'hafdefault');
		$mlist = main::expand_list($mlist, 'hafdefault', 'hafbest');
		$mlist = main::expand_list($mlist, 'hafbest', 'hafhigh,hafbetter');
		$mlist = main::expand_list($mlist, 'hafbetter', 'hafvgood');
		$mlist = main::expand_list($mlist, 'hafvgood', 'hafstd,hafgood');
		$mlist = main::expand_list($mlist, 'hafgood', 'hafmed,hafworse');
		$mlist = main::expand_list($mlist, 'hafworse', 'hafworst');
		$mlist = main::expand_list($mlist, 'hafworst', 'haflow');
	}
	# HLS on-demand TV and video clips
	if ( $prog->{type} eq "tv" && $mlist =~ /hls/ ) {
		$mlist = main::expand_list($mlist, 'hls', 'hlsdefault');
		$mlist = main::expand_list($mlist, 'hlsdefault', 'hlsbest');
		$mlist = main::expand_list($mlist, 'hlsbest', 'hlshd,hlsbetter');
		$mlist = main::expand_list($mlist, 'hlsbetter', 'hlsvgood');
		$mlist = main::expand_list($mlist, 'hlsvgood', 'hlsvhigh,hlsgood');
		$mlist = main::expand_list($mlist, 'hlsgood', 'hlsworse');
		$mlist = main::expand_list($mlist, 'hlsworse', 'hlsstd,hlsworst');
		$mlist = main::expand_list($mlist, 'hlsworst', 'hlsxstd');
	}
	# HLS audio clips
	if ( $prog->{type} eq "radio" && $mlist =~ /hlsaac/ ) {
		$mlist = main::expand_list($mlist, 'hlsaac', 'hlsaacdefault');
		$mlist = main::expand_list($mlist, 'hlsaacdefault', 'hlsaacbest');
		$mlist = main::expand_list($mlist, 'hlsaacbest', 'hlsaachigh,hlsaacbetter');
		$mlist = main::expand_list($mlist, 'hlsaacbetter', 'hlsaacvgood');
		$mlist = main::expand_list($mlist, 'hlsaacvgood', 'hlsaacstd,hlsaacgood');
		$mlist = main::expand_list($mlist, 'hlsaacgood', 'hlsaacworse');
		$mlist = main::expand_list($mlist, 'hlsaacworse', 'hlsaacworst');
		$mlist = main::expand_list($mlist, 'hlsaacworst', 'hlsaaclow');
	}
	# HLS Video Factory on-demand tv
	if ( $prog->{type} eq "tv" && $mlist =~ /hvf/ ) {
		$mlist = main::expand_list($mlist, 'hvf', 'hvfdefault');
		$mlist = main::expand_list($mlist, 'hvfdefault', 'hvfbest');
		if ( $opt->{fps50} ) {
			$mlist = main::expand_list($mlist, 'hvfbest', 'hvfhd,hvfbetter');
			$mlist = main::expand_list($mlist, 'hvfbetter', 'hvfsd,hvfxsd,hvfvgood');
			$mlist = main::expand_list($mlist, 'hvfvgood', 'hvfgood');
			$mlist = main::expand_list($mlist, 'hvfgood', 'hvfhigh,hvfxhigh,hvfworse');
		} else {
			$mlist = main::expand_list($mlist, 'hvfbest', 'hvfbetter');
			$mlist = main::expand_list($mlist, 'hvfbetter', 'hvfxsd,hvfvgood');
			$mlist = main::expand_list($mlist, 'hvfvgood', 'hvfgood');
			$mlist = main::expand_list($mlist, 'hvfgood', 'hvfxhigh,hvfworse');
		}
		$mlist = main::expand_list($mlist, 'hvfworse', 'hvfworst');
		$mlist = main::expand_list($mlist, 'hvfworst', 'hvflow');
	}
	# default on-demand radio
	if ( $prog->{type} eq "radio" && $mlist =~ /radio/ ) {
		$mlist = main::expand_list($mlist, 'radio', 'radiodefault');
		$mlist = main::expand_list($mlist, 'radiodefault', 'radiobest');
		$mlist = main::expand_list($mlist, 'radiobest', 'dafhigh,hafhigh,radiobetter');
		$mlist = main::expand_list($mlist, 'radiobetter', 'radiovgood');
		$mlist = main::expand_list($mlist, 'radiovgood', 'dafstd,hafstd,hlsaacstd,radiogood');
		$mlist = main::expand_list($mlist, 'radiogood', 'dafmed,hafmed,radioworse');
		$mlist = main::expand_list($mlist, 'radioworse', 'radioworst');
		$mlist = main::expand_list($mlist, 'radioworst', 'daflow,haflow,hlsaaclow');
	}
	# default on-demand tv
	if ( $prog->{type} eq "tv" && $mlist =~ /tv/ ) {
		$mlist = main::expand_list($mlist, 'tv', 'tvdefault');
		$mlist = main::expand_list($mlist, 'tvdefault', 'tvbest');
		if ( $opt->{fps50} ) {
			$mlist = main::expand_list($mlist, 'tvbest', 'hvfhd,dvfhd,hlshd,tvbetter');
			$mlist = main::expand_list($mlist, 'tvbetter', 'hvfsd,dvfsd,hvfxsd,dvfxsd,tvvgood');
			$mlist = main::expand_list($mlist, 'tvvgood', 'hlsvhigh,tvgood');
			$mlist = main::expand_list($mlist, 'tvgood', 'hvfhigh,dvfhigh,hvfxhigh,dvfxhigh,tvworse');
		} else {
			$mlist = main::expand_list($mlist, 'tvbest', 'hlshd,tvbetter');
			$mlist = main::expand_list($mlist, 'tvbetter', 'hvfxsd,dvfxsd,tvvgood');
			$mlist = main::expand_list($mlist, 'tvvgood', 'hlsvhigh,tvgood');
			$mlist = main::expand_list($mlist, 'tvgood', 'hvfxhigh,dvfxhigh,tvworse');
		}
		$mlist = main::expand_list($mlist, 'tvworse', 'hlsstd,hlsxstd,tvworst');
		$mlist = main::expand_list($mlist, 'tvworst', 'hvflow,dvflow');
	}
	return $mlist;
}


################### TV class #################
package Programme::tv;

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use HTML::Entities;
use HTTP::Cookies;
use HTTP::Headers;
use IO::Seekable;
use IO::Socket;
use LWP::ConnCache;
use LWP::UserAgent;
use POSIX qw(ceil mkfifo strftime);
use strict;
use Time::Local;
use URI;

# Inherit from Programme class
use base 'Programme::bbciplayer';

# Class vars
sub index_min { return 1 }
sub index_max { return 9999 }
sub channels {
	return {
		'national' => {
			'bbc_one'			=> 'BBC One',
			'bbc_two'			=> 'BBC Two',
			'bbc_four'			=> 'BBC Four',
			'bbc_sport'		=> 'BBC Sport',
			'cbbc'				=> 'CBBC',
			'cbeebies'			=> 'CBeebies',
			'bbc_news'		=> 'BBC News',
			'bbc_news24'		=> 'BBC News',
			'bbc_parliament'	=> 'BBC Parliament',
			'bbc_webonly'		=> 'BBC Web Only',
		},
		'regional' => {
			'bbc_alba'			=> 'BBC Alba',
			's4cpbs'			=> 'S4C'
		}
	};
}


# channel ids be found on http://www.bbc.co.uk/bbcone/programmes/schedules/today
sub channels_schedule {
	return {
		'national' => {
			'bbcone/programmes/schedules/hd'	=> 'BBC One',
			'bbctwo/programmes/schedules/hd'	=> 'BBC Two',
			'bbcfour/programmes/schedules'		=> 'BBC Four',
			'cbbc/programmes/schedules'		=> 'CBBC',
			'cbeebies/programmes/schedules'		=> 'CBeebies',
			'bbcnews/programmes/schedules'		=> 'BBC News',
			'bbcparliament/programmes/schedules'	=> 'BBC Parliament',
		},
		'regional' => {
			'bbcone/programmes/schedules/ni'	=> 'BBC One Northern Ireland',
			'bbcone/programmes/schedules/ni_hd'	=> 'BBC One Northern Ireland',
			'bbcone/programmes/schedules/scotland'	=> 'BBC One Scotland',
			'bbcone/programmes/schedules/scotland_hd'	=> 'BBC One Scotland',
			'bbcone/programmes/schedules/wales'	=> 'BBC One Wales',
			'bbcone/programmes/schedules/wales_hd'	=> 'BBC One Wales',
			'bbctwo/programmes/schedules/england'	=> 'BBC Two England',
			'bbctwo/programmes/schedules/ni'	=> 'BBC Two Northern Ireland',
			'bbctwo/programmes/schedules/scotland'	=> 'BBC Two Scotland',
			'bbctwo/programmes/schedules/wales'	=> 'BBC Two Wales',
			'bbcalba/programmes/schedules'		=> 'BBC Alba',
			's4c/programmes/schedules'		=> 'S4C',
		},
		'local' => {
			'bbcone/programmes/schedules/cambridge'	=> 'BBC One Cambridgeshire',
			'bbcone/programmes/schedules/channel_islands'	=> 'BBC One Channel Islands',
			'bbcone/programmes/schedules/east'	=> 'BBC One East',
			'bbcone/programmes/schedules/east_midlands'	=> 'BBC One East Midlands',
			'bbcone/programmes/schedules/london'	=> 'BBC One London',
			'bbcone/programmes/schedules/north_east'	=> 'BBC One North East & Cumbria',
			'bbcone/programmes/schedules/north_west'	=> 'BBC One North West',
			'bbcone/programmes/schedules/oxford'	=> 'BBC One Oxfordshire',
			'bbcone/programmes/schedules/south'	=> 'BBC One South',
			'bbcone/programmes/schedules/south_east'	=> 'BBC One South East',
			'bbcone/programmes/schedules/south_west'	=> 'BBC One South West',
			'bbcone/programmes/schedules/west'	=> 'BBC One West',
			'bbcone/programmes/schedules/west_midlands'	=> 'BBC One West Midlands',
			'bbcone/programmes/schedules/east_yorkshire'	=> 'BBC One Yorks & Lincs',
			'bbcone/programmes/schedules/yorkshire'	=> 'BBC One Yorkshire',
		}
	};
}


# Class cmdline Options
sub opt_format {
	return {
		tvmode		=> [ 1, "tvmode|vmode=s", 'Recording', '--tvmode <mode>,<mode>,...', "TV recording modes (overrides --modes): dvfhd,dvfsd,dvfxsd,dvfhigh,dvfxhigh,dvflow,hlshd,hlsvhigh,hlsstd,hlsxstd,hvfhd,hvfsd,hvfxsd,hvfhigh,hvfxhigh,hvflow. Shortcuts: worst,worse,vgood,better,best,dvf,hls,hvf (default=hlshd,hvfxsd,hlsvhigh,hvfxhigh,hlsstd,hlsxstd,hvflow)."],
		commandtv	=> [ 1, "commandtv|command-tv=s", 'Output', '--command-tv <command>', "Run user command after successful recording of tv programme using substitution paramaters such as <dir>, <fileprefix>, <filename>, etc. Overrides --command."],
		outputtv	=> [ 1, "outputtv=s", 'Output', '--outputtv <dir>', "Output directory for tv recordings (overrides --output)"],
	};
}



# Method to return optional list_entry format
sub optional_list_entry_format {
	my $prog = shift;
	my @format;
	for ( qw/ channel pid / ) {
		push @format, $prog->{$_} if defined $prog->{$_};
	}
	return ', '.join ', ', @format;
}


sub get_links_aod {
	my $self = shift;
	my $prog = shift;
	my $prog_type = shift;
	my $now = shift || time();
	my $force_channel_id = shift;
	my $two_days = 2 * 86400;
	my $thirty_days = 30 * 86400;
	my %channel_map = (
		'1xtra'			=> 'bbc_1xtra',
		'radio1'		=> 'bbc_radio_one',
		'radio2'		=> 'bbc_radio_two',
		'radio3'		=> 'bbc_radio_three',
		'radio4'		=> 'bbc_radio_four',
		'radio4extra'	=> 'bbc_radio_four_extra',
		'fivelive'		=> 'bbc_radio_five_live',
		'sportsextra'	=> 'bbc_radio_five_live_sports_extra',
		'6music'		=> 'bbc_6music',
		'asiannetwork'	=> 'bbc_asian_network',
		'radiofoyle'	=> 'bbc_radio_foyle',
		'radioscotland'	=> 'bbc_radio_scotland',
		'alba'			=> 'bbc_radio_nan_gaidheal',
		'radioulster'	=> 'bbc_radio_ulster',
		'radiowales'	=> 'bbc_radio_wales',
		'radiocymru'	=> 'bbc_radio_cymru',
		'worldservice'	=> 'bbc_world_service'
	);
	# Hack to get correct 'channels' method because this methods is being shared with Programme::radio
	my %channels = %{ main::progclass($prog_type)->channels_filtered( main::progclass($prog_type)->channels_aod() ) };
	my $bbc_prog_page_prefix = 'http://www.bbc.co.uk/programmes'; # /$pid
	# Download index feed
	my @channel_list = keys %channels;
	if ( $force_channel_id ) {
		@channel_list = ($force_channel_id)
	}
	for my $channel_id ( @channel_list ) {
		# Setup User agent
		my $ua = main::create_ua( 'desktop', 1 );
		my $url = "http://www.bbc.co.uk/radio/aod/availability/${channel_id}.xml";
		main::logger "\nDEBUG: Getting feed $url\n" if $opt->{verbose};
		my $xml = main::request_url_retry($ua, $url, 3, '.', "\nWARNING: Failed to get programme index feed for $channels{$channel_id}\n");
		if ( ! $xml ) {
			return 1 if $opt->{refreshabortonerror};
			next;
		}
		decode_entities($xml);
		# Parse XML
		# get list of entries within <entry> </entry> tags
		my @entries = split /<entry/, $xml;
		# Discard first element == header
		shift @entries;
		main::logger "\nINFO: Got ".($#entries + 1)." programmes for $channels{$channel_id}\n" if $opt->{verbose};
		foreach my $entry (@entries) {
			my ( $title, $name, $brand_pid, $series_pid, $brand, $series, $episode, $episodenum, $seriesnum, $desc, $pid, $available, $expires, $max_expires, $channel, $duration, $thumbnail, $version, $guidance );
			my ($available_str, $until_str);
			($available_str, $until_str) = ($1, $2) if $entry =~ m{<availability\s+start="(.*?)"\s+end="(.*?)"};
			next if ! $available_str;
			$available = Programme::get_time_string( $available_str );
			next if $available > $now;
			$max_expires = $expires = $available + $thirty_days;
			if ( $until_str ) {
				my $until = Programme::get_time_string( $until_str );
				$expires = $until if ($until - $available) < $two_days;
			}
			$expires = $max_expires if $expires > $max_expires;
			next if $expires < $now;
			$pid = $1 if $entry =~ m{<pid>(.+?)</pid>};
			if ( defined $prog->{$pid} ) {
				main::logger "WARNING: '$pid, $prog->{$pid}->{name} - $prog->{$pid}->{episode}, $prog->{$pid}->{channel}' already exists (this channel = $channel $available)\n" if $opt->{verbose};
				# use listing with earliest availability
				if ( $prog->{$pid}->{available} && $available_str lt $prog->{$pid}->{available} ) {
					$prog->{$pid}->{available} = $available_str;
				}
				# use listing with latest expiry
				if ( $prog->{$pid}->{expires} && $expires > $prog->{$pid}->{expires} ) {
					$prog->{$pid}->{expires} = $expires;
				}
				next;
			}
			$duration = $1 if $entry =~ m{duration="(.*?)"};
			$desc = $1 if $entry =~ m{<synopsis>(.*?)</synopsis>};
			$episode = $1 if $entry =~ m{<title>(.*?)</title>};
			($brand_pid, $brand) = ($1, $2) if $entry =~ m{<parent.*?pid="(.*?)".*?type="Brand">(.*?)</parent>};
			($series_pid, $series) = ($1, $2) if $entry =~ m{<parent.*?pid="(.*?)".*?type="Series">(.*?)</parent>};
			$episode =~ s/^\Q$brand\E:\s+// if $brand;
			$episode =~ s/^\Q$series\E:\s+// if $series;
			if ( $brand ) {
				if ( $series && $series ne $brand ) {
					$name = "$brand: $series";
				} else {
					$name = $brand;
				}
			} else {
					$name = $series;
			}
			unless ( $name ) {
				# determine name and episode from title
				#( $name, $episode ) = Programme::bbciplayer::split_title( $title );
				$name = $brand = $episode;
				$episode = "-";
			}
			# Extract the seriesnum
			my $regex = 'Series\s+'.main::regex_numbers();
			$seriesnum = main::convert_words_to_number( $1 ) if "$name $episode" =~ m{$regex}i;
			# Extract the episode num
			my $regex_1 = 'Episode\s+'.main::regex_numbers();
			my $regex_2 = '^'.main::regex_numbers().'\.\s+';
			if ( "$name $episode" =~ m{$regex_1}i ) {
				$episodenum = main::convert_words_to_number( $1 );
			} elsif ( $episode =~ m{$regex_2}i ) {
				$episodenum = main::convert_words_to_number( $1 );
			}
			# insert episode number in $episode
			#$episode = Programme::bbciplayer::insert_episode_number($episode, $episodenum);
			# Extract channel
			$channel = $channels{$channel_id};
			main::logger "DEBUG: '$pid, $name - $episode, $channel'\n" if $opt->{debug};
			# only default for radio
			$version = 'default';
			# no categories in AOD
			my @category;
			my $thumbsize = $opt->{thumbsizecache} || 150;
			my ($thumb_pid, $thumb_type, $thumbnail);
			($thumb_pid, $thumb_type) = ( $brand_pid , "brand" ) if $brand_pid;
			if ( ! ( $thumb_pid && $thumb_type ) ) {
				($thumb_pid, $thumb_type) = ( $series_pid , "series" ) if $series_pid;
			}
			if ( $thumb_pid && $thumb_type) {
				my $recipe = Programme::bbciplayer->thumb_url_recipes->{ $thumbsize };
				$recipe = Programme::bbciplayer->thumb_url_recipes->{ 150 } unless $recipe;
				$thumbnail = "http://ichef.bbci.co.uk/images/ic/${recipe}/legacy/${thumb_type}/${thumb_pid}.jpg";
			} else {
				$thumb_pid = $channel_map{$channel_id} || $channel_id;
				$thumbnail = "http://www.bbc.co.uk/iplayer/images/radio/${thumb_pid}_640_360.jpg";
			}
			# build data structure
			$prog->{$pid} = main::progclass($prog_type)->new(
				'pid'		=> $pid,
				'name'		=> $name,
				'versions'	=> $version,
				'episode'	=> $episode,
				'seriesnum'	=> $seriesnum,
				'episodenum'	=> $episodenum,
				'desc'		=> $desc,
				'guidance'	=> $guidance,
				'duration'	=> $duration || 'Unknown',
				'thumbnail'	=> $thumbnail,
				'channel'	=> $channel,
				'categories'	=> join(',', sort @category),
				'type'		=> $prog_type,
				'web'		=> "${bbc_prog_page_prefix}/${pid}",
				'available' => $available_str,
				'expires'	=> $expires,
			);
		}
	}
}


# Usage: Programme::tv->get_links( \%prog, 'tv' );
# Uses: %{ channels() }, \%prog
sub get_links {
	my $self = shift; # ignore obj ref
	my $prog = shift;
	my $prog_type = shift;
	my $now = shift || time();
	main::logger "\nINFO: Getting $prog_type Index Feeds (this may take a few minutes)\n";
	my $rc = 0;
	$rc = $self->get_links_schedule($prog, $prog_type, 0, $now);
	return 1 if $rc && $opt->{refreshabortonerror};
	if ( $opt->{refreshfuture} ) {
		$rc = $self->get_links_schedule($prog, $prog_type, 1, $now);
		return 1 if $rc && $opt->{refreshabortonerror};
	}
	main::logger "\n";
	return 0;
}


# get cache info for programmes from schedule
sub get_links_schedule {
	my $self = shift;
	my $prog = shift;
	my $prog_type = shift;
	my $future = shift;
	my $now = shift || time();
	if ( $opt->{ybbcy} ) {
		# check XML::LibXML here before using elsewhere
		eval "use XML::LibXML '1.70'";
		if ( $@ ) {
			main::logger "WARNING: Please download and run latest installer or install the XML::LibXML Perl module to index $prog_type programmes.\n";
			return;
		}
	}
	my @schedule_dates;
	my $limit = 0;
	my $one_week = 7 * 86400;
	my $then = $now - $one_week;
	my $this_year = (gmtime($now))[5];
	my $that_year = (gmtime($then))[5];
	my $this_week = strftime( "%W", gmtime($now) );
	my $that_week = strftime( "%W", gmtime($then) );
	my $cache_file = "${profile_dir}/${prog_type}.cache";
	my ($cache_this_week, $cache_last_week);
	if ( ! $opt->{cachereset} && -f $cache_file ) {
		my $cache_time = stat($cache_file)->mtime;
		my $cache_year = (gmtime($cache_time))[5];
		my $cache_week = strftime( "%W", gmtime($cache_time) );
		$cache_this_week = ( $this_year == $cache_year && $this_week == $cache_week );
		$cache_last_week = ( $that_year == $cache_year && $that_week == $cache_week );
	}
	if ( $future ) {
		push @schedule_dates, "this_week", "next_week";
	} else {
		my $limit_days = $opt->{"refreshlimit".${prog_type}} || $opt->{"refreshlimit"};
		$limit_days = 0 if $limit_days < 0;
		$limit_days = 30 if $limit_days > 30;
		$limit = $now - (ceil($limit_days / 7) * 7 * 86400) if $limit_days;
		if ( $limit ) {
			my $limit_time = $limit;
			my $limit_year = (gmtime($limit_time))[5];
			my $limit_week = strftime( "%W", gmtime($limit_time) );
			while ( $limit_time < $then ) {
				push @schedule_dates, sprintf("%04d/w%02d", $limit_year+1900, $limit_week+1);
				$limit_time += $one_week;
				$limit_year = (gmtime($limit_time))[5];
				$limit_week = strftime( "%W", gmtime($limit_time) );
			}
			push @schedule_dates, "this_week";
		} else {
			push @schedule_dates, "last_week" unless $cache_this_week;
			push @schedule_dates, "this_week";
		}
	}
	return unless @schedule_dates;
	my %channels = %{ main::progclass($prog_type)->channels_filtered( main::progclass($prog_type)->channels_schedule() ) };
	my @channel_list = sort keys %channels;
	if ( $opt->{ybbcy} && ! $opt->{noindexconcurrent} ) {
		eval "use Mojo::UserAgent";
		if ( ! $@ ) {
			main::logger "\nINFO: Using concurrent indexing\n";
			my @mojo_urls;
			my %mojo_channel_ids;
			my %mojo_channels;
			for my $channel_id ( @channel_list ) {
				for my $schedule_date ( @schedule_dates ) {
					my $mojo_url = "http://www.bbc.co.uk/${channel_id}/${schedule_date}";
					push @mojo_urls, $mojo_url;
					$mojo_channel_ids{$mojo_url} = $channel_id;
					$mojo_channels{$mojo_url} = $channels{$channel_id};
				}
			}
			my $rc = $self->get_links_schedule_mojo($prog, $prog_type, $future, $limit, $now, \@mojo_urls, \%mojo_channel_ids, \%mojo_channels);
			if ( $rc ) {
				return 1 if $opt->{refreshabortonerror};
			}
			return;
		}
	}
	my (%aod_channels, %aod_channel_ids);
	if ( $prog_type eq "radio" ) {
		%aod_channels = %{ main::progclass($prog_type)->channels_filtered( main::progclass($prog_type)->channels_aod() ) };
		if ( $opt->{ybbcy} ) {
			while ( my ($k1, $v1) = each %channels ) {
				keys %aod_channels;
				while ( my ($k2, $v2) = each %aod_channels ) {
					if ( $v1 eq $v2 ) {
						$aod_channel_ids{$k1} = $k2;
						last;
					}
				}
			}
		}
	}
	my $ua = main::create_ua( 'desktop', 1 );
	$ua->timeout(60) if $opt->{ybbcy};
	my $known_bad = "radiosolent";
	undef $known_bad if $opt->{ybbcy};
	my %aod_seen;
	main::logger "\nINFO: Using sequential indexing\n";
	for my $channel_id ( @channel_list ) {
		for my $schedule_date ( @schedule_dates ) {
			my ($url, $rc);
			if ( $opt->{ybbcy} ) {
				$url = "http://www.bbc.co.uk/${channel_id}/${schedule_date}";
				$rc = $self->get_links_schedule_html($ua, $prog, $prog_type, $channel_id, $channels{$channel_id}, $future, $url, $limit, $now, $known_bad);
			} else {
				$url = "http://www.bbc.co.uk/${channel_id}/${schedule_date}.xml";
				$rc = $self->get_links_schedule_page($ua, $prog, $prog_type, $channel_id, $channels{$channel_id}, $future, $url, $limit, $now, $known_bad);
			}
			if ( $rc ) {
				if ( $prog_type eq "radio" && ! $aod_seen{$channel_id} ) {
					my $aod_channel_id;
					keys %aod_channels;
					while ( my ($k, $v) = each %aod_channels ) {
						if ( $v eq $channels{$channel_id} ) {
							$aod_channel_id = $k;
							last;
						}
					}
					if ( $aod_channel_id ) {
						$aod_seen{$channel_id}++;
						if ( ! $future ) {
							main::logger "\nWARNING: Only previous 7 days of programmes will be indexed for $aod_channels{$aod_channel_id}\n" unless $channel_id =~ /$known_bad/;
							$rc = $self->get_links_aod($prog, $prog_type, $now, $aod_channel_id);
						} else {
							main::logger "WARNING: --refresh-future is not supported for $aod_channels{$aod_channel_id}\n";
						}
					}
				}
				if ( $rc ) {
					return 1 if $opt->{refreshabortonerror};
					next;
				}
			}
		}
	}
}

# get cache info from schedule html with Mojolicious
sub get_links_schedule_mojo {
	my $self = shift;
	my $prog = shift;
	my $prog_type = shift;
	my $future = shift;
	my $limit = shift;
	my $now = shift || time();
	my $urls = shift;
	my $channel_ids = shift;
	my $channels = shift;
	return 1 unless @$urls;
	eval "use Mojo::UserAgent";
	if ( $@ ) {
		main::logger "INFO: Mojo::UserAgent not available\n";
		return 1;
	}
	my $active = 0;
	my %attempts;
	my $rc_mojo;
	my $max_conn = $opt->{indexmaxconn} || 5;
	my $ua = Mojo::UserAgent->new(max_redirects => 5);
	$ua->transactor->name(main::user_agent());
	$ua->proxy->detect;
	$ua->connect_timeout(60);
	$ua->inactivity_timeout(60);
	
	my $get_callback = sub {
		my (undef, $tx) = @_;
		$active--;
		my $url = $tx->req->url;
		my $channel_id = $channel_ids->{$url};
		my $channel = $channels->{$url};
		my $code = $tx->res->code;
		my $html = $tx->res->body;
		unless ( $code >= 200 and $code < 300 and $html) {
			if ( $attempts{$url} < 3 ) {
				main::logger "\nDEBUG: Retrying download of schedule page: $url\n" if $opt->{verbose};
				unshift @$urls, $url;
			} else {
				main::logger "\nWARNING: Failed to download schedule page: $url\n";
				$rc_mojo = 1;
			}
			return;
		}
		my $rc = $self->get_links_schedule_html_page($html, $prog, $prog_type, $channel_id, $channel, $future, $limit, $now);
		if ( $rc ) {
			main::logger "\nWARNING: Failed to parse schedule page: $url\n";
			$rc_mojo = 1;
		}
	};
	
	my $delay = Mojo::IOLoop->delay;
	my $do_next;
	$do_next = sub {
		while ( $active < $max_conn and my $url = shift @$urls ) {
			last if ( $rc_mojo && $opt->{refreshabortonerror} );
			my $end = $delay->begin;
			$active++;
			$attempts{$url}++;
			main::logger ".";
			main::logger "\nDEBUG: Downloading schedule page ($attempts{$url}): $url\n" if $opt->{verbose};
			$ua->get($url => sub {
				my ($ua, $tx) = @_;
 				unless ( $rc_mojo && $opt->{refreshabortonerror} ) {
	 				$get_callback->($ua, $tx);
					$do_next->();
				}
				$end->();
			});
		}
	};
	
	$do_next->();
	$delay->wait unless $delay->ioloop->is_running;
	return 1 if $rc_mojo;
}

# get cache info from schedule html
sub get_links_schedule_html {
	my $self = shift;
	my $ua = shift;
	my $prog = shift;
	my $prog_type = shift;
	my $channel_id = shift;
	my $channel = shift;
	my $future = shift;
	my $url = shift;
	my $limit = shift;
	my $now = shift || time();
	my $known_bad = shift;
	main::logger "DEBUG: Getting feed $url\n" if $opt->{verbose};
	my $html = main::request_url_retry($ua, $url, 3, '.', "\nWARNING: Failed to download programme schedule $url\n");
	return 1 unless $html;
	return $self->get_links_schedule_html_page($html, $prog, $prog_type, $channel_id, $channel, $future, $limit, $now)
}

sub get_links_schedule_html_page {
	my $self = shift;
	my $html = shift;
	my $prog = shift;
	my $prog_type = shift;
	my $channel_id = shift;
	my $channel = shift;
	my $future = shift;
	my $limit = shift;
	my $now = shift || time();
	return 1 unless $html;
	eval "use XML::LibXML";
	if ( $@ ) {
		main::logger "INFO: XML::LibXML not available\n";
		return 1;
	}
	my $cache_channel = $channel;
	if ( $prog_type eq "tv" ) {
		# collapse BBC One/Two variants
		$cache_channel =~ s/(BBC (One|Two)).*/$1/;
	}
	my $bbc_prog_page_prefix = 'http://www.bbc.co.uk/programmes'; # /$pid
	my $thirty_days = 30 * 86400;
	my $min_available = $limit || ( $now - $thirty_days );
	my $dom = XML::LibXML->load_html(string => $html, recover => 1, suppress_errors => 1);
	my @entries = $dom->findnodes('//li[@class="week-guide__table__item"]');
	# get list of entries within <broadcast> </broadcast> tags
	main::logger "\nINFO: Got ".($#entries + 1)." programmes for $channel\n" if $opt->{verbose};
	foreach my $entry (@entries) {
		my ( $title, $name, $episode, $brand_pid, $series_pid, $brand, $series, $episodenum, $seriesnum, $desc, $pid, $available, $expires, $max_expires, $duration, $thumbnail, $version, $guidance, $descshort );
		my ($available_str, $until_str);
		my $pid = $entry->findvalue('.//div[@typeof="Episode" or @typeof="RadioEpisode"]/@data-pid');
		next unless $pid;
		my $available_str = $entry->findvalue('.//h3[@property="startDate"]/@content');
		next unless $available_str;
		$available = Programme::get_time_string( $available_str );
		next if $available < $min_available;
		next if ! $future && $available > $now;
		next if $future && $available <= $now;
		$expires = $available + $thirty_days;
		if ( defined $prog->{$pid} ) {
			main::logger "WARNING: '$pid, $prog->{$pid}->{name} - $prog->{$pid}->{episode}, $prog->{$pid}->{channel}' already exists (this channel = $channel $available)\n" if $opt->{verbose};
			# use listing with earliest availability
			if ( $prog->{$pid}->{available} && $available_str lt $prog->{$pid}->{available} ) {
				$prog->{$pid}->{available} = $available_str;
			}
			# use listing with latest expiry
			if ( $prog->{$pid}->{expires} && $expires > $prog->{$pid}->{expires} ) {
				$prog->{$pid}->{expires} = $expires;
			}
			next;
		}
		my $end_date = $entry->findvalue('.//meta[@property="endDate"]/@content');
		if ( $end_date ) {
			# compute duration
			my $finish = Programme::get_time_string( $end_date );
			if ( $finish ) {
				$duration = $finish - $available;
			}
		}
		$channel = $entry->findvalue('.//span[@typeof="BroadcastService"]/meta[@property="name"]/@content');
		$desc = $entry->findvalue('.//p[contains(@class,"programme__synopsis")]//span[@property="description"]');
		$desc =~ s/[\r\n]/ /g;
		my @title_nodes = $entry->findnodes('.//h4[@class="programme__titles"]//span[@property="name"]');
		my @titles = map {$_->findvalue('.')} @title_nodes;
		if ( $#titles == 2 ) {
			$name = "$titles[0]: $titles[1]";
			$episode = $titles[2];
		} elsif ( $#titles == 1 ) {
			$name = $titles[0];
			$episode = $titles[1];
		} elsif ( $#titles == 0 ) {
			$name = $titles[0];
			$episode = "-";
		}
		$episodenum = $entry->findvalue('.//p[contains(@class,"programme__synopsis")]//span[@property="position"]');
		if ( ! $episodenum ) {
			# Extract the episode num
			my $regex_1 = 'Episode\s+'.main::regex_numbers();
			my $regex_2 = '^'.main::regex_numbers().'\.\s+';
			if ( $episode =~ m{$regex_1}i ) {
				$episodenum = main::convert_words_to_number( $1 );
			} elsif ( $episode =~ m{$regex_2}i ) {
				$episodenum = main::convert_words_to_number( $1 );
			}
		}
		# Extract the seriesnum
		my $regex = 'Series\s+'.main::regex_numbers();
		$seriesnum = main::convert_words_to_number( $1 ) if "$name $episode" =~ m{$regex}i;
		# only default version in schedules
		$version = 'default';
		# build data structure
		decode_entities($name);
		decode_entities($episode);
		decode_entities($desc);
		$prog->{$pid} = main::progclass($prog_type)->new(
			'pid'		=> $pid,
			'name'		=> $name,
			'versions'	=> $version,
			'episode'	=> $episode,
			'seriesnum'	=> $seriesnum,
			'episodenum'	=> $episodenum,
			'desc'		=> $desc,
			'duration'	=> $duration,
			'thumbnail'	=> $thumbnail,
			'channel'	=> $cache_channel,
			'type'		=> $prog_type,
			'web'		=> "${bbc_prog_page_prefix}/${pid}",
			'available' => $available_str,
			'expires' => $expires,
		);
	}
}


# get cache info from schedule page
sub get_links_schedule_page {
	my $self = shift;
	my $ua = shift;
	my $prog = shift;
	my $prog_type = shift;
	my $channel_id = shift;
	my $channel = shift;
	my $future = shift;
	my $url = shift;
	my $limit = shift;
	my $now = shift || time();
	my $known_bad = shift;
	my $cache_channel = $channel;
	if ( $prog_type eq "tv" ) {
		# collapse BBC One/Two variants
		$cache_channel =~ s/(BBC (One|Two)).*/$1/;
	}
	my $bbc_prog_page_prefix = 'http://www.bbc.co.uk/programmes'; # /$pid
	main::logger "DEBUG: Getting feed $url\n" if $opt->{verbose};
	my $warning = "\nWARNING: Failed to download programme schedule $url\n" unless $channel_id =~ /$known_bad/;
	my $xml = main::request_url_retry($ua, $url, 3, '.', $warning);
	return 1 if ! $xml;
	decode_entities($xml);

	# <broadcast is_repeat="0" is_blanked="0">
	# 	<pid>p0290kxs</pid>
	# 	<start>2014-10-31T11:00:00Z</start>
	# 	<end>2014-10-31T11:45:00Z</end>
	# 	<duration>2700</duration>
	# 	<programme type="episode">
	# 		<pid>b04n8rx0</pid>
	# 		<position>10</position>
	# 		<title>Episode 10</title>
	# 		<short_synopsis>Council officers deal with home owners living on top of deadly waste.</short_synopsis>
	# 		<media_type>audio_video</media_type>
	# 		<duration>2700</duration>
	# 		<image>
	# 			<pid>p028r5jx</pid>
	# 		</image>
	# 		<display_titles>
	# 			<title>Call the Council</title>
	# 			<subtitle>Series 2, Episode 10</subtitle>
	# 		</display_titles>
	# 		<first_broadcast_date>2014-10-31T11:00:00Z</first_broadcast_date>
	# 		<ownership>
	# 			<service type="tv" id="bbc_one" key="bbcone">
	# 				<title>BBC One</title>
	# 			</service>
	# 		</ownership>
	# 		<programme type="series">
	# 			<pid>b04mlq1k</pid>
	# 			<title>Series 2</title>
	# 			<position>2</position>
	# 			<image>
	# 				<pid>p028r5jx</pid>
	# 			</image>
	# 			<expected_child_count>10</expected_child_count>
	# 			<first_broadcast_date>2014-10-20T11:00:00+01:00</first_broadcast_date>
	# 			<ownership>
	# 				<service type="tv" id="bbc_one" key="bbcone">
	# 					<title>BBC One</title>
	# 				</service>
	# 			</ownership>
	# 			<programme type="brand">
	# 				<pid>b04mlpdd</pid>
	# 				<title>Call the Council</title>
	# 				<position/>
	# 				<image>
	# 					<pid>p028r5jx</pid>
	# 				</image>
	# 				<expected_child_count/>
	# 				<first_broadcast_date>2014-05-19T11:30:00+01:00</first_broadcast_date>
	# 				<ownership>
	# 					<service type="tv" id="bbc_one" key="bbcone">
	# 						<title>BBC One</title>
	# 					</service>
	# 				</ownership>
	# 			</programme>
	# 		</programme>
	# 		<available_until>2014-12-03T07:45:00Z</available_until>
	# 		<actual_start>2014-10-31T11:45:00Z</actual_start>
	# 		<is_available_mediaset_pc_sd>1</is_available_mediaset_pc_sd>
	# 		<is_legacy_media>0</is_legacy_media>
	# 		<media format="video">
	# 			<expires>2014-12-03T07:45:00Z</expires>
	# 			<availability>1 month left to watch</availability>
	# 		</media>
	# 	</programme>
	# </broadcast>

	my $thirty_days = 30 * 86400;
	my $min_available = $limit || ( $now - $thirty_days );
	# get list of entries within <broadcast> </broadcast> tags
	my @entries = split /<broadcast[^s]/, $xml;
	# Discard first element == header
	shift @entries;
	main::logger "\nINFO: Got ".($#entries + 1)." programmes for $channel\n" if $opt->{verbose};
	foreach my $entry (@entries) {
		my ( $title, $name, $episode, $brand_pid, $series_pid, $brand, $series, $episodenum, $seriesnum, $desc, $pid, $available, $expires, $max_expires, $duration, $thumbnail, $version, $guidance, $descshort, $channel );
		my ($available_str, $until_str);
		$available_str = $1 if $entry =~ m{<end>\s*(.+?)\s*</end>};
		if ( ! $available_str ) {
			$available_str = $1 if $entry =~ m{<start>\s*(.+?)\s*</start>};
		}
		next if ! $available_str;
		$available = Programme::get_time_string( $available_str );
		next if $available < $min_available;
		next if ! $future && $available > $now;
		next if $future && $available <= $now;
		$until_str = $1 if $entry =~ m{<available_until>(.*?)</available_until>};
		if ( ! $until_str ) {
			$until_str = $1 if $entry =~ m{<expires>(.*?)</expires>};
		}
		if ( ! $future ) {
			$max_expires = $expires = $available + $thirty_days;
			if ( $until_str ) {
				my $until = Programme::get_time_string( $until_str );
				$expires = $until if $until < $expires;
			}
			$expires = $max_expires if $expires > $max_expires;
			next if $expires < $now;
		}
		$pid = $1 if $entry =~ m{<programme\s+type="episode">.*?<pid>\s*(.+?)\s*</pid>};
		if ( defined $prog->{$pid} ) {
			main::logger "WARNING: '$pid, $prog->{$pid}->{name} - $prog->{$pid}->{episode}, $prog->{$pid}->{channel}' already exists (this channel = $channel $available)\n" if $opt->{verbose};
			# use listing with earliest availability
			if ( $prog->{$pid}->{available} && $available_str lt $prog->{$pid}->{available} ) {
				$prog->{$pid}->{available} = $available_str;
			}
			# use listing with latest expiry
			if ( $prog->{$pid}->{expires} && $expires > $prog->{$pid}->{expires} ) {
				$prog->{$pid}->{expires} = $expires;
			}
			next;
		}
		$channel = $1 if $entry =~ m{<programme\s+type="episode">.*?<ownership>.*?<service\s+.*?>.*?<title>\s*(.*?)\s*</title>};
		unless ( $prog_type eq "radio" && $channel eq "BBC Local Radio" ) {
			$channel = $cache_channel;
		}
		$desc = $1 if $entry =~ m{<short_synopsis>\s*(.+?)\s*</short_synopsis>};
		$duration = $1 if $entry =~ m{<duration>\s*(.+?)\s*</duration>};
		$episode = $1 if $entry =~ m{<programme\s+type="episode">.*?<title>\s*(.*?)\s*</title>};
		($brand_pid, $brand) = ($1, $2) if $entry =~ m{<programme\s+type="brand">.*?<pid>\s*(.*?)\s*</pid>.*?<title>\s*(.*?)\s*</title>.*?</programme>};
		($series_pid, $series) = ($1, $2) if $entry =~ m{<programme\s+type="series">.*?<pid>\s*(.*?)\s*</pid>.*?<title>\s*(.*?)\s*</title>.*?</programme>};
		if ( $brand ) {
			if ( $series && $series ne $brand ) {
				$name = "$brand: $series";
			} else {
				$name = $brand;
			}
		} else {
			$name = $series;
		}
		unless ( $name ) {
			$name = $brand = $episode;
			$episode = "-";
		}
		# Extract the seriesnum
		my $regex = 'Series\s+'.main::regex_numbers();
		$seriesnum = main::convert_words_to_number( $1 ) if "$name $episode" =~ m{$regex}i;
		my $series_position = $1 if $entry =~ m{<programme\s+type="series">.*?<position>\s*(.+?)\s*</position>};
		$seriesnum ||= $series_position;
		# Extract the episode num
		my $regex_1 = 'Episode\s+'.main::regex_numbers();
		my $regex_2 = '^'.main::regex_numbers().'\.\s+';
		if ( $episode =~ m{$regex_1}i ) {
			$episodenum = main::convert_words_to_number( $1 );
		} elsif ( $episode =~ m{$regex_2}i ) {
			$episodenum = main::convert_words_to_number( $1 );
		}
		my $episode_position = $1 if $entry =~ m{<programme\s+type="episode">.*?<position>\s*(.+?)\s*</position>};
		$episodenum ||= $episode_position;
		# insert episode number in $episode
		#$episode = Programme::bbciplayer::insert_episode_number($episode, $episodenum);
		main::logger "DEBUG: '$pid, $name - $episode, $channel'\n" if $opt->{debug};
		# Merge and Skip if this pid is a duplicate
		# only default version in schedules
		$version = 'default';
		# thumbnail options
		# http://ichef.bbci.co.uk/programmeimages/p01m1x5p/b04l8sml_640_360.jpg
		# http://ichef.bbci.co.uk/images/ic/640x360/p01m1x5p.jpg
		# Default to 150px width thumbnail;
		my $thumbsize = $opt->{thumbsizecache} || 150;
		my $image_pid = $1 if $entry =~ m{<image><pid>(.*?)</pid>}s;
		my $series_image_pid = $1 if $entry =~ m{<programme\s+type="series">.*?<image><pid>(.*?)</pid>};
		my $brand_image_pid = $1 if $entry =~ m{<programme\s+type="brand">.*?<image><pid>(.*?)</pid>};
		if ( $series_image_pid ) {
			$image_pid = $series_image_pid;
		} elsif ( $brand_image_pid ) {
			$image_pid = $brand_image_pid;
		}
		my $suffix = Programme::bbciplayer->thumb_url_suffixes->{ $thumbsize };
		$suffix = Programme::bbciplayer->thumb_url_suffixes->{ 150 } unless $suffix;
		my $thumbnail = "http://ichef.bbci.co.uk/programmeimages/${image_pid}/${pid}${suffix}";
		# build data structure
		$prog->{$pid} = main::progclass($prog_type)->new(
			'pid'		=> $pid,
			'name'		=> $name,
			'versions'	=> $version,
			'episode'	=> $episode,
			'seriesnum'	=> $seriesnum,
			'episodenum'	=> $episodenum,
			'desc'		=> $desc,
			'duration'	=> $duration,
			'thumbnail'	=> $thumbnail,
			'channel'	=> $channel,
			'type'		=> $prog_type,
			'web'		=> "${bbc_prog_page_prefix}/${pid}",
			'available' => $available_str,
			'expires' => $expires,
		);
	}
}


# Usage: download (<prog>, <ua>, <mode>, <version>, <version_pid>)
sub download {
	my ( $prog, $ua, $mode, $version, $version_pid ) = ( @_ );

	# require ffmpeg for HLS
	if ( $mode =~ /^(hls|hvf|haf)/ && ! $opt->{raw} && ! main::exists_in_path('ffmpeg') ) {
		main::logger "WARNING: Required ffmpeg utility not found - not converting .ts file\n";
		$opt->{raw} = 1;
	}
	# cannot convert hvf with avconv or ffmpeg < 2.5
	if ( $mode =~ /^hvf/ && ! $opt->{raw} ) {
		if ( $opt->{ffmpegav} ) {
			main::logger "WARNING: avconv does not support conversion of hvf downloads to MP4 - not converting .ts file\n";
			$opt->{raw} = 1;
		} elsif ( $opt->{ffmpegxx} ) {
			main::logger "WARNING: Unable to determine ffmpeg version - MP4 conversion for hvf downloads may fail\n";
		} elsif ( ! $opt->{ffmpeg25} ) {
			main::logger "WARNING: Your version of ffmpeg ($opt->{ffmpegversion}) does not support conversion of hvf downloads to MP4 - not converting .ts file\n";
			$opt->{raw} = 1;
		}
		if ( $opt->{ffmpegav} || $opt->{ffmpegxx} || ! $opt->{ffmpeg25} ) {
			main::logger "WARNING: ffmpeg 2.5 or higher is required to convert hvf downloads to MP4\n";
			main::logger "WARNING: Use --raw to bypass MP4 conversion and retain .ts file\n";
			main::logger "WARNING: Use --ffmpeg-force to override checks and force MP4 conversion attempt\n";
		}
	}
	# require ffmpeg for DASH
	if ( $mode =~ /^(daf|dvf)/ && ! $opt->{raw} && ! main::exists_in_path('ffmpeg') ) {
		main::logger "WARNING: Required ffmpeg utility not found - not converting .m4a and .m4v files\n";
		$opt->{raw} = 1;
	}
	# cannot convert dvf with avconv or ffmpeg < 3.0
	if ( $mode =~ /^dvf/ && ! $opt->{raw} ) {
		if ( $opt->{ffmpegav} ) {
			main::logger "WARNING: avconv does not support conversion of dvf downloads to MP4 - not converting .m4a and .m4v files\n";
			$opt->{raw} = 1;
		} elsif ( $opt->{ffmpegxx} ) {
			main::logger "WARNING: Unable to determine ffmpeg version - MP4 conversion for dvf downloads may fail\n";
		} elsif ( ! $opt->{ffmpeg30} ) {
			main::logger "WARNING: Your version of ffmpeg ($opt->{ffmpegversion}) does not support conversion of dvf downloads to MP4 - not converting .m4a and .m4v files\n";
			$opt->{raw} = 1;
		}
		if ( $opt->{ffmpegav} || $opt->{ffmpegxx} || ! $opt->{ffmpeg30} ) {
			main::logger "WARNING: ffmpeg 3.0 or higher is required to convert dvf downloads to MP4\n";
			main::logger "WARNING: Use --raw to bypass MP4 conversion and retain .m4a and .m4v files\n";
			main::logger "WARNING: Use --ffmpeg-force to override checks and force MP4 conversion attempt\n";
		}
	}

	# Determine the correct filenames for this recording
	if ( my $rc = $prog->generate_filenames( $ua, $prog->file_prefix_format(), $mode, $version ) ) {
		return 'stop' if $rc == 3;
		return 'skip';
	}

	# Create dir for prog
	if ( ! ( $opt->{nowrite} || $opt->{test} ) ) {
		$prog->create_dir();
	}

	# Skip from here if we are only testing recordings
	return 'skip' if $opt->{test};

	# Get subtitles if they exist and are required
	# best to do this before streaming file so that the subtitles can be enjoyed while recording progresses
	my $subfile_done;
	my $subfile;
	if ( $opt->{subtitles} ) {
		$subfile_done = "$prog->{dir}/$prog->{fileprefix}.srt";
		$subfile = "$prog->{dir}/$prog->{fileprefix}.partial.srt";
		main::logger "\n";
		if ( $prog->download_subtitles( $ua, $subfile, [ $version ] ) && $opt->{subsrequired} && $prog->{type} eq 'tv') {
			main::logger "WARNING: Subtitles not available and --subsrequired specified.\n";
			return 'skip';
		}
	}

	my $return = 0;
	# Only get the stream if we are writing a file
	if ( ! $opt->{nowrite} ) {
		# set mode
		$prog->{mode} = $mode;

		# Disable proxy here if required
		main::proxy_disable($ua) if $opt->{partialproxy};

		# Instantiate new streamer based on streamdata
		my $class = "Streamer::$prog->{streams}->{$version}->{$mode}->{streamer}";
		if ( ! $class->can('new') ) {
			main::logger "ERROR: Cannot instantiate streamer for class=$class version=$version mode=$mode\n";
			return 'skip';
		}
		my $stream = $class->new;

		# Do recording
		$return = $stream->get( $ua, $prog->{streams}->{$version}->{$mode}->{streamurl}, $prog, %{ $prog->{streams}->{$version}->{$mode} } );

		# Re-enable proxy here if required
		main::proxy_enable($ua) if $opt->{partialproxy};
	}

	# Rename the subtitle file accordingly if the stream get was successful
	move($subfile, $subfile_done) if $opt->{subtitles} && -f $subfile && ! $return;

	return $return;
}



# BBC iPlayer TV
# Download Subtitles, convert to srt(SubRip) format and apply time offset
# Todo: get the subtitle streamurl before this...
sub download_subtitles {
	my $prog = shift;
	my ( $ua, $file, $versions ) = @_;
	my $subs;
	my $found;

	# in case --subtitles used with --pid for radio programme
	return unless $prog->{type} eq "tv";
	
	# Don't redownload subs if the file already exists
	if ( ( -f $file || -f "$prog->{dir}/$prog->{fileprefix}.partial.srt" ) && ! $opt->{overwrite} ) {
		main::logger "INFO: Skipping subtitles download - file already exists: $file\n" if $opt->{verbose};
		return 0;
	}

	# Find subtitles stream
	for my $version ( @$versions ) {
		my @subkeys = grep /subtitles/, sort keys %{$prog->{streams}->{$version}};
		for my $subkey ( @subkeys ) {
			my $suburl = $prog->{streams}->{$version}->{$subkey}->{streamurl};
			if ( $suburl ) {
				$found = 1;
				main::logger "INFO: Getting subtitles from $suburl\n" if $opt->{verbose};
				$subs = main::request_url_retry($ua, $suburl, 3);
				last if $subs;
			}
		}
		last if $subs;
	}
	# Return if we have no url
	if (! $found) {
		my $vermsg = " for version(s): ".(join ',', @$versions) if @$versions;
		main::logger "INFO: Subtitles not available${vermsg}\n";
		return 2;
	}
	if (! $subs ) {
		main::logger "ERROR: Subtitle download failed\n";
		return 1;
	} else {
		# Dump raw subs into a file if required
		if ( $opt->{subsraw} ) {
			unlink("$prog->{dir}/$prog->{fileprefix}.ttxt");
			main::logger "INFO: Downloading raw subtitles to: $prog->{dir}/$prog->{fileprefix}.ttxt\n";
			open( my $fhraw, "> $prog->{dir}/$prog->{fileprefix}.ttxt");
			print $fhraw $subs;
			close $fhraw;
		}
		main::logger "INFO: Downloading subtitles to: $prog->{dir}/$prog->{fileprefix}.srt\n";
	}

	# Convert the format to srt
	# SRT:
	#1
	#00:01:22,490 --> 00:01:26,494
	#Next round!
	#
	#2
	#00:01:33,710 --> 00:01:37,714
	#Now that we've moved to paradise, there's nothing to eat.
	#

	# TT:
	#<p begin="0:01:12.400" end="0:01:13.880">Thinking.</p>
	#<p begin="00:01:01.88" id="p15" end="00:01:04.80"><span tts:color="cyan">You're thinking of Hamburger Hill...<br /></span>Since we left...</p>
	#<p begin="00:00:18.48" id="p0" end="00:00:20.52">APPLAUSE AND CHEERING</p>
	# There is also a multiline form:
	#<p region="speaker" begin="00:00:01.840" end="00:00:08.800"><span style="textStyle">  This programme contains  <br/>
	#                  some strong language</span></p>
	# And a form with explicit namespace:
	#<tt:p xml:id="C80" begin="00:08:45.440" end="00:08:49.240" style="s2">It was in 2000. At the beginning,<tt:br />it was different.</tt:p>

	if ( $opt->{subsfmt} ) {
		my @subsfmts = qw/compact default original/;
		if ( ! grep /^$opt->{subsfmt}$/i, @subsfmts ) {
			main::logger "WARNING: Invalid value specified for --subsfmt: $opt->{subsfmt}. Must be one of: @subsfmts. Using default subtitles format.\n";
			$opt->{subsfmt} = "default";
		}
		# Open subs file
		open( my $fh, "> $file" );

		my ($ns) = $subs =~ m{<(\w+:)p\b};
		my $p = $ns.'p';
		my $span = $ns.'span';
		my $br = $ns.'br';
		my $count = 0;
		for ( $subs =~ m{<$p\b.+?</$p>}gis ) {
			my ( $begin, $end, $sub ) = ( m{\bbegin="(.+?)".*?\bend="(.+?)".*?>(.+?)</$p>}is );
			if ( $begin && $end && $sub ) {
				($begin = sprintf( '%02d:%02d:%06.3f', split /:/, $begin )) =~ s/\./,/;
				($end = sprintf( '%02d:%02d:%06.3f', split /:/, $end )) =~ s/\./,/;
				if ($opt->{suboffset}) {
					$begin = main::subtitle_offset( $begin, $opt->{suboffset} );
					$end = main::subtitle_offset( $end, $opt->{suboffset} );
				}
				# remove line breaks, squeeze whitespace, fix up <br> and <span>
				$sub =~ s|\n+||g;
				$sub =~ s/(^\s+|\s+$)//g;
				$sub =~ s|\s+| |g;
				$sub =~ s|(\s?<$br.*?>\s?)+|<br/>|gi;
				$sub =~ s!(^<br/>|<br/>$)!!g;
				$sub =~ s|<br/>(</$span>)$|$1|i;
				$sub =~ s|(<$span.*?>)\s|$1|i;
				# separate individual lines based on <span>s
				$sub =~ s|<$span.*?>(.*?)</$span>|\n$1\n|gi;
				if ($sub =~ m{\n}) {
					# fix up line breaks
					$sub =~ s/(^\n|\n$)//g;
					# add leading hyphens
					$sub =~ s|\n+|\n- |g;
					if ( $sub =~ m{\n-} ) {
						$sub =~ s|^|- |;
					}
				}
				if ( $opt->{subsfmt} eq 'compact' ) {
					$sub =~ s|\n+||g;
					# embed line breaks
					$sub =~ s|<br/>|\n|g;
				} else {
					# remove <br/> elements
					$sub =~ s|\n- <br/>\n|\n|g;
					$sub =~ s|\n- <br/>|\n- |g;
					$sub =~ s|<br/>| |g;
				}
				decode_entities($sub);
				# Write to file
				print $fh ++$count, "\n";
				print $fh "$begin --> $end\n";
				print $fh "$sub\n\n";
			}
		}
		close $fh;

		if ( ! $count ) {
			main::logger "WARNING: Subtitles empty\n";
			return 3;
		}
	} else {
		return ttml_to_srt( $subs, $file, $opt->{subsmono}, $opt->{suboffset} );
	}

	return 0;
}

sub ttml_to_srt {
	my $ttml = shift;
	my $srt = shift;
	my $mono = shift;
	my $offset = shift;
	my $prefix = "\n- ";
	my $index = 0;
	my %hex_colors = (
		'black'   => '#000000',
		'blue'    => '#0000ff',
		'green'   => '#00ff00',
		'lime'    => '#00ff00',
		'aqua'    => '#00ffff',
		'cyan'    => '#00ffff',
		'red'     => '#ff0000',
		'fuchsia' => '#ff00ff',
		'magenta' => '#ff00ff',
		'yellow'  => '#ffff00',
		'white'   => '#ffffff'
	);

	eval "use XML::LibXML '1.70'";
	if ( $@ ) {
		print "WARNING: Please download and run latest installer or install the XML::LibXML Perl module to convert subtitles.\n";
		return 1;
	}

	use Text::Wrap qw(fill $columns $huge);
	$columns = 37;
	$huge = 'overflow';

	use XML::LibXML::XPathContext;
	my $dom = XML::LibXML->load_xml(string => $ttml);
	my $xpc = XML::LibXML::XPathContext->new($dom);
	my ($doc) = $xpc->findnodes('/*');
	$xpc->registerNs('tt', $doc->namespaceURI());		
	my @ns = $xpc->findnodes("/*/namespace::*");
	for my $ns (@ns) {
		if ( $ns->getLocalName() && $ns->getValue() ) {
			$xpc->registerNs($ns->getLocalName(), $ns->getValue());
		}
	}
	my $fps;
	eval { $fps = $xpc->findvalue('/*/@ttp:frameRate') };
	my %style_colors;
	foreach my $style ($xpc->findnodes('//tt:styling/tt:style')) {
		my $style_id = $style->findvalue('@id');
		if ($style_id) {
			my $style_color;
			eval { $style_color = $style->findvalue('@tts:color') };
			if ($style_color) {
				my $style_hex = $hex_colors{$style_color};
				if ($style_hex) {
					$style_colors{$style_id} = $style_hex;
				}
			}
		}
	}
	my ($body) = $xpc->findnodes('//tt:body');
	my $body_style = $body->findvalue('@style');
	my $body_color = $style_colors{$body_style} || $hex_colors{'white'};
	my $curr_color = $body_color;

	open( my $fh, "> $srt" );
	for my $div ($xpc->findnodes('tt:div', $body)) {
		my $div_style = $div->findvalue('@style');
		my $div_color = $style_colors{$div_style} || $body_color;
		$curr_color = $div_color;
		for my $p ($xpc->findnodes('tt:p', $div)) {
			my @times;
			for my $key ('begin', 'end') {
				my $val = $p->findvalue("\@$key");
				my @parts = split /:/, $val;
				if ( $#parts == 3 ) {
					my $frames = pop @parts;
					if ( $fps ) {
						my $fraction = $frames / $fps;
						$parts[$#parts] += $fraction;
					}
				}
				(my $time = sprintf( '%02d:%02d:%06.3f', @parts )) =~ s/\./,/;
				push @times, $time;
			}
			my ($begin, $end) = @times;
			next unless $begin && $end;
			if ( $offset ) {
				$begin = main::subtitle_offset( $begin, $offset );
				$end = main::subtitle_offset( $end, $offset );
			}
			my $text;
			my $p_color;
			my $p_style = $p->findvalue('@style');
			if ($p_style) {
				$p_color = $style_colors{$p_style};
			} else {
				eval { $p_color = $hex_colors{$p->findvalue('@tts:color')} };
			}
			$p_color ||= $div_color;
			for my $p_child ($p->childNodes) {
				if ($p_child->nodeName eq "br") {
					$text .= "\n";
				} elsif ($p_child->nodeName eq "#text") {
					my $p_text = $p_child->to_literal();
					if ($p_text) {
						if ($mono) {
							if ($p_color ne $curr_color) {
								$curr_color = $p_color;
								$text .= $prefix;
							}
							$text .= $p_text;
						} else {
							$text .= "<font color=\"$p_color\">$p_text</font>";
						}
					}
				} elsif ($p_child->nodeName eq "span") {
					my $span = $p_child;
					my $span_color;
					my $span_style = $span->findvalue('@style');
					if ($span_style) {
						$span_color = $style_colors{$span_style};
					} else {
						eval { $span_color = $hex_colors{$span->findvalue('@tts:color')} };
					}
					$span_color ||= $p_color;
					for my $span_child ($span->childNodes) {
						if ($span_child->nodeName eq "br") {
							$text .= "\n";
						} elsif ($span_child->nodeName eq "#text") {
							my $span_text = $span_child->to_literal();
							if ($span_text) {
								if ($mono) {
									if ($span_color ne $curr_color) {
										$curr_color = $span_color;
										$text .= $prefix;
									}
									$text .= $span_text;
								} else {
									$text .= "<font color=\"$span_color\">$span_text</font>";
								}
							}
						}
					}
				}
			}
			if ($mono) {
				$text =~ s/\n([^-])/ $1/g;
				$text =~ s/\n-/\n\n-/g;
				$text = join("", fill('', '', $text));
			}
			$text =~ s/(^\s+|\s+$)//g;
			$text =~ s/\n{2,}/\n/g;
			print $fh ++$index."\n$begin --> $end\n$text\n\n";
		}	
	}
	close $fh;
	if ( ! $index ) {
		main::logger "WARNING: Subtitles empty\n";
		return 3;
	}
	return 0;
}


################### Radio class #################
package Programme::radio;

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use HTML::Entities;
use HTTP::Cookies;
use HTTP::Headers;
use IO::Seekable;
use IO::Socket;
use LWP::ConnCache;
use LWP::UserAgent;
use POSIX qw(mkfifo);
use strict;
use Time::Local;
use URI;

# Inherit from Programme class
use base 'Programme::bbciplayer';

# Class vars
sub index_min { return 10001 }
sub index_max { return 39999 };
sub channels_aod {
	return {
		'national' => {
			'radio1'		=> 'BBC Radio 1',
			'1xtra'			=> 'BBC Radio 1Xtra',
			'radio2'		=> 'BBC Radio 2',
			'radio3'		=> 'BBC Radio 3',
			'radio4'		=> 'BBC Radio 4',
			'radio4extra'	=> 'BBC Radio 4 Extra',
			'fivelive'		=> 'BBC Radio 5 live',
			'sportsextra'	=> 'BBC Radio 5 live sports extra',
			'6music'		=> 'BBC Radio 6 Music',
			'asiannetwork'	=> 'BBC Asian Network',
			'worldservice'	=> 'BBC World Service',
		},
		'regional' => {
			'radiofoyle'	=> 'BBC Radio Foyle',
			'radioscotland'	=> 'BBC Radio Scotland',
			'alba'			=> 'BBC Radio Nan Gaidheal',
			'radioulster'	=> 'BBC Radio Ulster',
			'radiowales'	=> 'BBC Radio Wales',
			'radiocymru'	=> 'BBC Radio Cymru',
		},
		'local' => {
			'bbc_radio_cumbria'			=> 'BBC Radio Cumbria',
			'bbc_radio_newcastle'			=> 'BBC Newcastle',
			'bbc_tees'				=> 'BBC Tees',
			'bbc_radio_lancashire'			=> 'BBC Radio Lancashire',
			'bbc_radio_merseyside'			=> 'BBC Radio Merseyside',
			'bbc_radio_manchester'			=> 'BBC Radio Manchester',
			'bbc_radio_leeds'			=> 'BBC Radio Leeds',
			'bbc_radio_sheffield'			=> 'BBC Radio Sheffield',
			'bbc_radio_york'			=> 'BBC Radio York',
			'bbc_radio_humberside'			=> 'BBC Radio Humberside',
			'bbc_radio_lincolnshire'		=> 'BBC Radio Lincolnshire',
			'bbc_radio_nottingham'			=> 'BBC Radio Nottingham',
			'bbc_radio_leicester'			=> 'BBC Radio Leicester',
			'bbc_radio_derby'			=> 'BBC Radio Derby',
			'bbc_radio_stoke'			=> 'BBC Radio Stoke',
			'bbc_radio_shropshire'			=> 'BBC Radio Shropshire',
			'bbc_wm'				=> 'BBC WM 95.6',
			'bbc_radio_coventry_warwickshire'	=> 'BBC Coventry & Warwickshire',
			'bbc_radio_hereford_worcester'		=> 'BBC Hereford & Worcester',
			'bbc_radio_northampton'			=> 'BBC Radio Northampton',
			'bbc_three_counties_radio'		=> 'BBC Three Counties Radio',
			'bbc_radio_cambridge'			=> 'BBC Radio Cambridgeshire',
			'bbc_radio_norfolk'			=> 'BBC Radio Norfolk',
			'bbc_radio_suffolk'			=> 'BBC Radio Suffolk',
			'bbc_radio_essex'			=> 'BBC Essex',
			'bbc_london'				=> 'BBC Radio London',
			'bbc_radio_kent'			=> 'BBC Radio Kent',
			'bbc_radio_surrey'			=> 'BBC Surrey',
			'bbc_radio_sussex'			=> 'BBC Sussex',
			'bbc_radio_oxford'			=> 'BBC Radio Oxford',
			'bbc_radio_berkshire'			=> 'BBC Radio Berkshire',
			'bbc_radio_solent'			=> 'BBC Radio Solent',
			'bbc_radio_gloucestershire'		=> 'BBC Radio Gloucestershire',
			'bbc_radio_wiltshire'			=> 'BBC Wiltshire',
			'bbc_radio_bristol'			=> 'BBC Radio Bristol',
			'bbc_radio_somerset_sound'		=> 'BBC Somerset',
			'bbc_radio_devon'			=> 'BBC Radio Devon',
			'bbc_radio_cornwall'			=> 'BBC Radio Cornwall',
			'bbc_radio_guernsey'			=> 'BBC Radio Guernsey',
			'bbc_radio_jersey'			=> 'BBC Radio Jersey',
		}
	};
}

sub channels {
	return {
		'national' => {
			'bbc_radio_one'				=> 'BBC Radio 1',
			'bbc_radio_two'				=> 'BBC Radio 2',
			'bbc_radio_three'			=> 'BBC Radio 3',
			'bbc_radio_four'			=> 'BBC Radio 4',
			'bbc_radio_five_live'			=> 'BBC Radio 5 live',
			'bbc_world_service'			=> 'BBC World Service',
			'bbc_1xtra'				=> 'BBC Radio 1Xtra',
			'bbc_radio_four_extra'			=> 'BBC Radio 4 Extra',
			'bbc_radio_five_live_sports_extra'	=> 'BBC Radio 5 live sports extra',
			'bbc_6music'				=> 'BBC Radio 6 Music',
			'bbc_asian_network'			=> 'BBC Asian Network',
		},
		'regional' => {
			'bbc_radio_foyle'			=> 'BBC Radio Foyle',
			'bbc_radio_scotland'			=> 'BBC Radio Scotland',
			'bbc_radio_nan_gaidheal'		=> 'BBC Radio Nan Gaidheal',
			'bbc_radio_ulster'			=> 'BBC Radio Ulster',
			'bbc_radio_wales'			=> 'BBC Radio Wales',
			'bbc_radio_cymru'			=> 'BBC Radio Cymru',
		},
		'local' => {
			'bbc_radio_cumbria'			=> 'BBC Radio Cumbria',
			'bbc_radio_newcastle'			=> 'BBC Newcastle',
			'bbc_tees'				=> 'BBC Tees',
			'bbc_radio_lancashire'			=> 'BBC Radio Lancashire',
			'bbc_radio_merseyside'			=> 'BBC Radio Merseyside',
			'bbc_radio_manchester'			=> 'BBC Radio Manchester',
			'bbc_radio_leeds'			=> 'BBC Radio Leeds',
			'bbc_radio_sheffield'			=> 'BBC Radio Sheffield',
			'bbc_radio_york'			=> 'BBC Radio York',
			'bbc_radio_humberside'			=> 'BBC Radio Humberside',
			'bbc_radio_lincolnshire'		=> 'BBC Radio Lincolnshire',
			'bbc_radio_nottingham'			=> 'BBC Radio Nottingham',
			'bbc_radio_leicester'			=> 'BBC Radio Leicester',
			'bbc_radio_derby'			=> 'BBC Radio Derby',
			'bbc_radio_stoke'			=> 'BBC Radio Stoke',
			'bbc_radio_shropshire'			=> 'BBC Radio Shropshire',
			'bbc_wm'				=> 'BBC WM 95.6',
			'bbc_radio_coventry_warwickshire'	=> 'BBC Coventry & Warwickshire',
			'bbc_radio_hereford_worcester'		=> 'BBC Hereford & Worcester',
			'bbc_radio_northampton'			=> 'BBC Radio Northampton',
			'bbc_three_counties_radio'		=> 'BBC Three Counties Radio',
			'bbc_radio_cambridge'			=> 'BBC Radio Cambridgeshire',
			'bbc_radio_norfolk'			=> 'BBC Radio Norfolk',
			'bbc_radio_suffolk'			=> 'BBC Radio Suffolk',
			'bbc_radio_essex'			=> 'BBC Essex',
			'bbc_london'				=> 'BBC Radio London',
			'bbc_radio_kent'			=> 'BBC Radio Kent',
			'bbc_radio_surrey'			=> 'BBC Surrey',
			'bbc_radio_sussex'			=> 'BBC Sussex',
			'bbc_radio_oxford'			=> 'BBC Radio Oxford',
			'bbc_radio_berkshire'			=> 'BBC Radio Berkshire',
			'bbc_radio_solent'			=> 'BBC Radio Solent',
			'bbc_radio_gloucestershire'		=> 'BBC Radio Gloucestershire',
			'bbc_radio_wiltshire'			=> 'BBC Wiltshire',
			'bbc_radio_bristol'			=> 'BBC Radio Bristol',
			'bbc_radio_somerset_sound'		=> 'BBC Somerset',
			'bbc_radio_devon'			=> 'BBC Radio Devon',
			'bbc_radio_cornwall'			=> 'BBC Radio Cornwall',
			'bbc_radio_guernsey'			=> 'BBC Radio Guernsey',
			'bbc_radio_jersey'			=> 'BBC Radio Jersey',
		}
	};
}


# channel ids be found on http://www.bbc.co.uk/radio/stations
sub channels_schedule {
	return {
		'national' => {
			'radio1/programmes/schedules/england'	=> 'BBC Radio 1',
			'1xtra/programmes/schedules'		=> 'BBC Radio 1Xtra',
			'radio2/programmes/schedules'		=> 'BBC Radio 2',
			'radio3/programmes/schedules'		=> 'BBC Radio 3',
			'radio4/programmes/schedules/fm'	=> 'BBC Radio 4',
			'radio4/programmes/schedules/lw'	=> 'BBC Radio 4',
			'radio4extra/programmes/schedules'	=> 'BBC Radio 4 Extra',
			'5live/programmes/schedules'		=> 'BBC Radio 5 live',
			'5livesportsextra/programmes/schedules'	=> 'BBC Radio 5 live sports extra',
			'6music/programmes/schedules'		=> 'BBC Radio 6 Music',
			'asiannetwork/programmes/schedules'	=> 'BBC Asian Network',
			'worldserviceradio/programmes/schedules/uk'	=> 'BBC World Service',
		},
		'regional' => {
			'radioscotland/programmes/schedules/fm'	=> 'BBC Radio Scotland',
			'radioscotland/programmes/schedules/orkney'	=> 'BBC Radio Scotland',
			'radioscotland/programmes/schedules/shetland'	=> 'BBC Radio Scotland',
			'radioscotland/programmes/schedules/highlandsandislands'	=> 'BBC Radio Scotland',
			'radioscotland/programmes/schedules/mw'	=> 'BBC Radio Scotland',
			'radionangaidheal/programmes/schedules'	=> 'BBC Radio Nan Gaidheal',
			'radioulster/programmes/schedules'		=> 'BBC Radio Ulster',
			'radiofoyle/programmes/schedules'		=> 'BBC Radio Foyle',
			'radiowales/programmes/schedules/fm'	=> 'BBC Radio Wales',
			'radiowales/programmes/schedules/mw'	=> 'BBC Radio Wales',
			'radiocymru/programmes/schedules'		=> 'BBC Radio Cymru',
		},
		'local' => {
			'radioberkshire/programmes/schedules'	=> 'BBC Radio Berkshire',
			'radiobristol/programmes/schedules'		=> 'BBC Radio Bristol',
			'radiocambridgeshire/programmes/schedules'	=> 'BBC Radio Cambridgeshire',
			'radiocornwall/programmes/schedules'	=> 'BBC Radio Cornwall',
			'bbccoventryandwarwickshire/programmes/schedules'	=> 'BBC Coventry & Warwickshire',
			'radiocumbria/programmes/schedules'		=> 'BBC Radio Cumbria',
			'radioderby/programmes/schedules'		=> 'BBC Radio Derby',
			'radiodevon/programmes/schedules'		=> 'BBC Radio Devon',
			'bbcessex/programmes/schedules'			=> 'BBC Essex',
			'radiogloucestershire/programmes/schedules'	=> 'BBC Radio Gloucestershire',
			'radioguernsey/programmes/schedules'		=> 'BBC Radio Guernsey',
			'bbcherefordandworcester/programmes/schedules'	=> 'BBC Hereford & Worcester',
			'radiohumberside/programmes/schedules'	=> 'BBC Radio Humberside',
			'radiojersey/programmes/schedules'		=> 'BBC Radio Jersey',
			'radiokent/programmes/schedules'		=> 'BBC Radio Kent',
			'radiolancashire/programmes/schedules'	=> 'BBC Radio Lancashire',
			'radioleeds/programmes/schedules'		=> 'BBC Radio Leeds',
			'radioleicester/programmes/schedules'	=> 'BBC Radio Leicester',
			'radiolincolnshire/programmes/schedules'	=> 'BBC Radio Lincolnshire',
			'radiolondon/programmes/schedules'		=> 'BBC Radio London',
			'radiomanchester/programmes/schedules'	=> 'BBC Radio Manchester',
			'radiomerseyside/programmes/schedules'	=> 'BBC Radio Merseyside',
			'bbcnewcastle/programmes/schedules'		=> 'BBC Newcastle',
			'radionorfolk/programmes/schedules'		=> 'BBC Radio Norfolk',
			'radionorthampton/programmes/schedules'	=> 'BBC Radio Northampton',
			'radionottingham/programmes/schedules'	=> 'BBC Radio Nottingham',
			'radiooxford/programmes/schedules'		=> 'BBC Radio Oxford',
			'radiosheffield/programmes/schedules'	=> 'BBC Radio Sheffield',
			'radioshropshire/programmes/schedules'	=> 'BBC Radio Shropshire',
			'radiosolent/programmes/schedules'		=> 'BBC Radio Solent',
			'bbcsomerset/programmes/schedules'		=> 'BBC Somerset',
			'radiostoke/programmes/schedules'		=> 'BBC Radio Stoke',
			'radiosuffolk/programmes/schedules'		=> 'BBC Radio Suffolk',
			'bbcsurrey/programmes/schedules'		=> 'BBC Surrey',
			'bbcsussex/programmes/schedules'		=> 'BBC Sussex',
			'bbctees/programmes/schedules'			=> 'BBC Tees',
			'threecountiesradio/programmes/schedules'	=> 'BBC Three Counties Radio',
			'bbcwiltshire/programmes/schedules'		=> 'BBC Wiltshire',
			'wm/programmes/schedules'				=> 'BBC WM 95.6',
			'radioyork/programmes/schedules'		=> 'BBC Radio York',
		}
	};
}


# Class cmdline Options
sub opt_format {
	return {
		radiomode	=> [ 1, "radiomode|amode=s", 'Recording', '--radiomode <mode>,<mode>,...', "Radio recording modes (overrides --modes): dafhigh,dafstd,dafmed,daflow,hafhigh,hafstd,hafmed,haflow,hlsaacstd,hlsaaclow. Shortcuts: worst,worse,good,vgood,better,best,daf,haf,hlsaac (default=dafhigh,hafhigh,dafstd,hafstd,hlsaacstd,dafmed,hafmed,daflow,haflow,hlsaaclow)."],
		commandradio	=> [ 1, "commandradio|command-radio=s", 'Output', '--command-radio <command>', "Run user command after successful recording of radio programme using substitution paramaters such as <dir>, <fileprefix>, <filename>, etc. Overrides --command."],
		outputradio	=> [ 1, "outputradio=s", 'Output', '--outputradio <dir>', "Output directory for radio recordings (overrides --output)"],
	};
}



# This gets run before the download retry loop if this class type is selected
sub init {
}



# Method to return optional list_entry format
sub optional_list_entry_format {
	my $prog = shift;
	my @format;
	for ( qw/ channel pid / ) {
		push @format, $prog->{$_} if defined $prog->{$_};
	}
	return ', '.join ', ', @format;
}



# Default minimum expected download size for a programme type
sub min_download_size {
	return 102400;
}


sub get_links {
	shift;
	# Delegate to Programme::tv (same function is used)
	return Programme::tv->get_links(@_);
}



sub download {
	# Delegate to Programme::tv (same function is used)
	return Programme::tv::download(@_);
}


################### Streamer class #################
package Streamer;
use File::stat;
use File::Basename;
use File::Copy;
use strict;
use Text::ParseWords;

# Class vars
# Global options
my $optref;
my $opt;


# Constructor
# Usage: $streamer = Streamer->new();
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	# Ensure the subclass $opt var is pointing to the Superclass global optref
	$opt = $Streamer::optref;
	bless $self, $type;
}


# Use to bind a new options ref to the class global $optref var
sub add_opt_object {
	my $self = shift;
	$Streamer::optref = shift;
}


# $opt->{<option>} access method
sub opt {
	my $self = shift;
	my $optname = shift;
	return $opt->{$optname};
}

sub opt_format {
	return {
		ffmpeg		=> [ 0, "ffmpeg=s", 'External Program', '--ffmpeg <path>', "Location of ffmpeg binary. Assumed to be ffmpeg 3.0 or higher unless --ffmpeg-obsolete is specified."],
		ffmpegobsolete		=> [ 1, "ffmpeg-obsolete|ffmpegobsolete!", 'External Program', '--ffmpeg-obsolete', "Indicates you are using an obsolete version of ffmpeg (<1.0) that may not support certain options. Without this option, MP4 conversion may fail with obsolete versions of ffmpeg."],
		ffmpegforce		=> [ 1, "ffmpeg-force|ffmpegforce!", 'External Program', '--ffmpeg-force', "Bypass version checks and assume ffmpeg is version 3.0 or higher"],
		ffmpegverbose		=> [ 1, "ffmpeg-verbose|ffmpegverbose!", 'External Program', '--ffmpeg-verbose', "Show verbose (-loglevel verbose) output from ffmpeg"],
	};
}

sub remux {
	my ( $self, $audio_file, $video_file, $prog, %streamdata ) = @_;
	my @cmd;
	my $return;

	# do nothing if no files
	my $audio_ok = $audio_file && -f $audio_file;
	my $video_ok = $video_file && -f $video_file;
	return 0 unless ( $audio_ok || $video_ok);

	my @global_opts = ( '-y' );
	my @input_opts;
	push @input_opts, ( '-i', $audio_file ) if $audio_ok;
	push @input_opts, ( '-i', $video_file ) if $video_ok;
	my @codec_opts;
	if ( ! $opt->{ffmpegobsolete} ) {
		push @codec_opts, ( '-c:v', 'copy', '-c:a', 'copy' );
		if ( $opt->{notag} ) {
			push @codec_opts, ( '-movflags', 'faststart' );
		}
	} else {
		push @codec_opts, ( '-vcodec', 'copy', '-acodec', 'copy' );
	}
	my @filter_opts;
	if ( $prog->{mode} =~ /(haf|hvf|hls)/ ) {
		# need filter for HLS
		if ( ! $opt->{ffmpegobsolete} ) {
			push @filter_opts, ( '-bsf:a', 'aac_adtstoasc' );
		} else {
			push @filter_opts, ( '-absf', 'aac_adtstoasc' );
		}
	}

	@cmd = (
		$bin->{ffmpeg},
		@{ $binopts->{ffmpeg} },
		@global_opts,
		@input_opts,
		@codec_opts,
		@filter_opts,
		$prog->{filepart},
	);

	if ( $audio_ok && $video_ok ) {
		main::logger "INFO: Begin converting files:\n";
		main::logger "INFO: Audio file: $audio_file\n";
		main::logger "INFO: Video file: $video_file\n";
	} else {
		main::logger "INFO: Begin converting audio file: $audio_file\n" if $audio_ok;
		main::logger "INFO: Begin converting video file: $video_file\n" if $video_ok;
	}

	# Run conversion and delete source file on success
	$return = main::run_cmd( 'STDERR', @cmd );

	my $min_download_size = main::progclass($prog->{type})->min_download_size();

	if ( (! $return) && -f $prog->{filepart} && stat($prog->{filepart})->size > $min_download_size ) {
		unlink( $audio_file, $video_file );
		main::logger "INFO: Converted to file: $prog->{filepart}\n";
	} else {
		# remove the failed converted file
		unlink $prog->{filepart};
		main::logger "WARNING: Conversion failed - retaining audio file: $audio_file\n" if $audio_ok;
		main::logger "WARNING: Conversion failed - retaining video file: $video_file\n" if $video_ok;
		return 0;
	}
	# Moving file into place as complete
	if ( ! move($prog->{filepart}, $prog->{filename}) ) {
		main::logger "ERROR: Could not rename file: $prog->{filepart}\n";
		main::logger "ERROR: Destination file name: $prog->{filename}\n";
		return 'skip';
	}
	main::logger "INFO: Recorded file: $prog->{filename}\n";

	return 0;
}


################### Streamer::hls class #################
package Streamer::hls;

# Inherit from Streamer class
use base 'Streamer';

use File::Basename;
use File::Copy;
use File::Path;
use File::Spec;
use File::stat;
use List::Util qw(max);
use strict;
use Text::ParseWords;
use URI;

sub opt_format {
	return {
		noresume	=> [ 1, "no-resume|noresume!", 'Recording', '--no-resume', "Do not resume partial HLS/DASH downloads."],
		noverify	=> [ 1, "no-verify|noverify!", 'Recording', '--no-verify', "Do not verify size of downloaded HLS/DASH file segments or file resize upon resume."],
	};
}

sub parse_playlist {
	my (undef, $ua, $url) = @_;
	my $playlist_url = $url;
	main::logger "DEBUG: HLS playlist URL: $playlist_url\n" if $opt->{verbose};
	# resolve playlist redirect
	for (my $i = 0; $i < 3; $i++) {
		my $request = HTTP::Request->new( HEAD => $playlist_url );
		my $response = $ua->request($request);
		if ( $response->is_success ) {
			if ( $response->previous ) {
				$playlist_url = $response->request->uri;
				main::logger "DEBUG: HLS playlist URL (actual): $playlist_url\n" if $opt->{verbose};
			}
			last;
		}
	}
	my $data = main::request_url_retry($ua, $playlist_url, 3, undef, "\nWARNING: Failed to download HLS playlist: $playlist_url\n", 1);
	return undef if ! $data;
	my @lines = split(/\r?\n/, $data);
	if ( @lines < 1 || $lines[0] ne '#EXTM3U' ) {
		main::logger "WARNING: Invalid HLS playlist (no header): $playlist_url\n";
		return undef;
	}
	my $sequence = 0;
	my $segment_duration = 0;
	my $segments;
	foreach my $line (@lines) {
		next if $line =~ /^\s*$/;
		next if $line =~ /^##/;
		if ($line =~ /^#EXT-X-MEDIA-SEQUENCE:(\d+)$/) {
			$sequence = $1;
		} elsif ($line =~ /^#EXTINF:([\d\.]+)/) {
			$segment_duration = $1;
		} elsif ($line !~ /^#/) {
			my $segment_url = $line;
			if ( $segment_url !~ /^http/ ) {
				($segment_url = $playlist_url) =~ s/[^\/]+\.m3u8/$line/;
			}
			$segments->{$sequence} = { 'url' => $segment_url, 'duration' => $segment_duration };
			$segment_duration = 0;
			$sequence++;
		} else {
			$segment_duration = 0;
		}
	}
	return $segments;
}

sub get {
	my ( $self, $ua, $url, $prog, %streamdata ) = @_;
	my $rc;

	# media file
	my $media_type = $prog->{type} eq "tv" ? "video" : "audio";
	my $media_prefix = $prog->{fileprefix};
	my $media_tmp = main::encode_fs(File::Spec->catfile($prog->{dir}, "${media_prefix}.${media_type}.ts"));
	my $media_file = main::encode_fs(File::Spec->catfile($prog->{dir}, "${media_prefix}.hls.ts"));
	my $media_raw = $prog->{filename};

	if ( $opt->{overwrite} ) {
		main::logger "INFO: Overwriting HLS $media_type file: $media_file\n" if -f $media_file;
		unlink $media_file;
	} else {
		if ( -f $media_file ) {
			main::logger "INFO: Using existing HLS $media_type file: $media_file\n";
			main::logger "INFO: Use --overwrite to re-download\n";
		}
	}

	unless ( -f $media_file ) {
		my $segments = $self->parse_playlist($ua, $url);
		if ( keys %{$segments} == 0 ) {
			main::logger "ERROR: No file segments in HLS playlist\n";
			main::logger "ERROR: HLS playlist URL: $url\n";
			return 'next';
		}
		$rc = $self->fetch( $ua, $segments, $media_tmp, $prog, %streamdata );
		return $rc if $rc;
		if ( ! move($media_tmp, $media_file) ) {
			main::logger "ERROR: Could not rename file: $media_tmp\n";
			main::logger "ERROR: Destination file name: $media_file\n";
			return 'skip';
		}
		main::logger "INFO: Saved HLS $media_type file: $media_file\n";
	}
	if ( $opt->{raw} ) {
		if ( ! move($media_file, $media_raw) ) {
			main::logger "ERROR: Could not rename file: $media_file\n";
			main::logger "ERROR: Destination file name: $media_raw\n";
			return 'skip';
		}
		main::logger "INFO: Recorded raw $media_type file: $media_raw\n";
		return 0;
	}

	my ($audio_file, $video_file) = $prog->{type} eq "tv" ? (undef, $media_file) : ($media_file, undef);
	return $self->remux($audio_file, $video_file, $prog, %streamdata);
}

sub fetch {
	my ( $self, $ua, $segments, $file_tmp, $prog, %streamdata ) = @_;
	my $return;
	my $fh;
	my $rh;
	my $media_size = $streamdata{file_size};
	my $media_bitrate = $streamdata{media_bitrate} || $streamdata{bitrate};
	my $begin_time = time();
	my $begin_size = 0;
	my $percent = 0;
	my $size = 0;
	my $elapsed = 0;
	my $hash_count = 0;
	my $prev_percent = 0;
	my $prev_sequence = 0;
	my $prev_size = 0;
	my $prev_elapsed = 0;
	my $start_sequence = 0;
	my $start_elapsed = 0;
	my $stop_sequence = 0;
	my $stop_elapsed = 0;
	my $stop_elapsed_str = "--:--:--";
	my $resume_sequence = 0;
	my $resume_size = 0;
	my $resume_elapsed = 0;
	my $resume_begin = 0;
	my $curr_percent = 0;
	my $curr_sequence = 0;
	my $curr_size = 0;
	my $curr_elapsed = 0;
	my $curr_segment_url;
	my $total_duration = 0;
	my $file_duration = 0;
	my $file_size = 0;
	my $proxy_prefix;
	my $resuming = 0;
	my $retries = 3;
	my $rate_bps;
	my $hide_progress = main::hide_progress();
	my $crlf = ( $hide_progress || $opt->{logprogress} ) ? "\n" : "\r";
	my $noresume = $opt->{noresume};

	# LWP download callback
	my $callback = sub {
		my ($data, $res, undef) = @_;
		return 0 if ( ! $res->is_success || ! $res->header("Content-Length") );
		if ( ! print $fh $data ) {
			main::logger "ERROR: Cannot write to $file_tmp\n";
			exit 1;
		}
		$size = tell $fh;
		return if $opt->{quiet} || $opt->{silent};
		$percent = $file_size ? 100.0 * $curr_size / $file_size : 0;
		# limit progress display to 99.9%
		if ( $percent > 99.9 ) {
			$curr_percent = 99.9;
			$curr_size = int($file_size * 0.999);
			$curr_elapsed = int($stop_elapsed * 0.999);
		} else {
			$curr_percent = $percent;
			$curr_size = $size;
			$curr_elapsed = $elapsed;
		}
		if ( $opt->{hash} || $opt->{logprogress} ) {
			return if ($curr_percent - $prev_percent) < 1;
		} else {
			return if ($curr_percent - $prev_percent) < 0.1;
		}
		$prev_percent = $curr_percent;
		if ( $opt->{hash} ) {
			main::logger '#';
			$hash_count++;
			if ( ! ($hash_count % 100) ) {
				main::logger "\n";
			}
		} else {
			return if $hide_progress;
			my $rate;
			my $time;
			my $time_called = time();
			if ($time_called - $begin_time < 1) {
				$rate = '----.- Mibit/s';
				$time = '--:--:-- remaining';
			} else {
				$rate_bps = ($curr_size - $begin_size) / ($time_called - $begin_time);
				$rate = sprintf("%6.1f Mibit/s", (8.0 / 1024.0 / 1024.0) * $rate_bps);
				$time = sprintf("%02d:%02d:%02d remaining", ( gmtime( max(0, ($file_size - $curr_size)) / $rate_bps ) )[2,1,0] );
			}
			if ( $opt->{verbose} ) {
				main::logger sprintf ( "Recording: %8.2f MiB / ~%.2f MiB (%02d:%02d:%02d / %8s) [%5d / %d] %5.1f%% %s %s${crlf}",
					$curr_size / 1024.0 / 1024.0,
					$file_size / 1024.0 / 1024.0,
					(gmtime($curr_elapsed))[2,1,0],
					$stop_elapsed_str,
					$curr_sequence,
					$stop_sequence,
					$curr_percent,
					$rate,
					$time,
				);
			} else {
				main::logger sprintf ( "Recording: %8.2f MiB / ~%.2f MiB %5.1f%% %s %s${crlf}",
					$curr_size / 1024.0 / 1024.0,
					$file_size / 1024.0 / 1024.0,
					$curr_percent,
					$rate,
					$time,
				);
			}
		}
	};

	# set up sequence list
	my @sequences = sort { $a <=> $b } keys %{$segments};
	my $min_sequence = $sequences[0];
	my $max_sequence = $sequences[$#sequences];
	my $init_sequence;
	if ( $segments->{$min_sequence}->{initialization} ) {
		# capture DASH init segment
		$init_sequence = $min_sequence;
		$min_sequence = $sequences[1];
	}

	# resume file
	my $resume_params = "$prog->{pid},$prog->{version},$prog->{modeshort},".($opt->{start} || 0).",".($opt->{stop} || 0);
	my $resume_prefix = fileparse($file_tmp, qr/\.[^.]+/);
	my $resume_file = File::Spec->catfile($prog->{dir}, $resume_prefix.".txt");

	# remove resume file with --no-resume
	unlink $resume_file if $noresume;
	# look for resume file and initialise
	if ( ! $noresume && -f $resume_file ) {
		if ( ! open $rh, "<", $resume_file ) {
			main::logger "ERROR: Cannot open (read): $resume_file\n";
			exit 1;
		}
		my @resume_data = <$rh>;
		close $rh;
		if ( $#resume_data > 0 ) {
			chomp(my $last_params = $resume_data[0]);
			if ( $last_params =~ /^#(\w+,){3}\d+,\d+/ ) {
				$last_params =~ s/^#//;
				if ( $last_params eq $resume_params ) {
					chomp(my $last_data = $resume_data[$#resume_data]);
					if ( $last_data =~ /^(\d+,){2}[\.\d]+,\d+,[\.\d]+,\d+/ ) {
						my ($last_sequence, $last_size, $last_elapsed) = split /,/, $last_data;
						if ( $last_sequence > 0 && $last_size > 0 && $last_elapsed > 0 ) {
							my $tmp_size = -s $file_tmp || 0;
							if ( $last_sequence >= $max_sequence ) {
								main::logger "WARNING: Unexpected resume sequence ($last_sequence >= $max_sequence)\n";
								main::logger "WARNING: Restarting download\n";
							} elsif ( $last_size > $tmp_size ) {
								main::logger "WARNING: Unexpected resume size ($last_size > $tmp_size)\n";
								main::logger "WARNING: Restarting download\n";
							} else {
								$prev_sequence = $last_sequence;
								$resume_sequence = $last_sequence + 1;
								$resume_size = $last_size;
								$resume_elapsed = $last_elapsed;
								$resuming = 1;
							}
						} else {
							main::logger "WARNING: Unexpected resume data: $last_data\n";
							main::logger "WARNING: Restarting download\n";
						}
					} else {
						main::logger "WARNING: Invalid resume data: $last_data\n";
						main::logger "WARNING: Restarting download\n";
					}
				} else {
					if ( $opt->{verbose} ) {
						main::logger "INFO: Resume parameters changed: $last_params != $resume_params\n";
						main::logger "INFO: Restarting download\n";
					}
				}
			} else {
				main::logger "WARNING: Invalid resume parameters: $last_params\n";
				main::logger "WARNING: Restarting download\n";
			}
		}
	}
	unlink $resume_file unless $resuming;
	$begin_size = $prev_size = $size = $resume_size;

	# find duration and start/stop points
	for my $sequence ( $min_sequence..$max_sequence ) {
		my $segment = $segments->{$sequence};
		my $segment_duration = $segment->{duration};
		$total_duration += $segment_duration;
		if ( $start_sequence < 1 && defined $opt->{start} && $total_duration > $opt->{start} ) {
			$start_sequence = $sequence;
			$start_elapsed = $total_duration - $segment_duration;
		};
		if ( $stop_sequence < 1 && defined $opt->{stop} && $total_duration >= $opt->{stop} ) {
			$stop_sequence = $sequence;
			$stop_elapsed = $total_duration;
		}
	}
	$start_sequence ||= $min_sequence;
	$start_elapsed ||= 0;
	$stop_sequence ||= $max_sequence;
	$stop_elapsed ||= $total_duration;
	$stop_elapsed_str = sprintf("%02d:%02d:%02d", (gmtime($stop_elapsed))[2,1,0]);
	$resume_sequence ||= $start_sequence;
	$resume_elapsed ||= $start_elapsed;
	$prev_elapsed = $elapsed = $resume_elapsed;
	# estimate expected file size
	$media_size ||= int($total_duration * $media_bitrate * 1024.0 / 8.0);
	$file_duration = $stop_elapsed - $start_elapsed;
	$file_size = int($file_duration / $total_duration * $media_size);

	# open files
	if ( $resuming ) {
		# open output file for resume
		if ( ! open($fh, ">>:raw", $file_tmp) ) {
			main::logger "ERROR: Cannot open (append): $file_tmp\n";
			exit 1;
		}
		binmode $fh;
		$fh->autoflush(1);
		my $tmp_size = -s $file_tmp || 0;
		# overwrite any partial segment appended in last run
		if ( $resume_size < $tmp_size ) {
			main::logger "INFO: Resizing file: $file_tmp\n";
			main::logger "INFO: Resizing from $tmp_size to $resume_size for resume\n";
			if ( ! truncate($fh, $resume_size) || ! seek($fh, 0, 2) ) {
				$resuming = 0;
				close $fh;
				main::logger "WARNING: Unable to resize file: $file_tmp\n";
				main::logger "WARNING: Restarting download\n";
			} else {
				unless ( $opt->{noverify} ) {
					my $trunc_size = tell $fh;
					if ( $trunc_size != $resume_size ) {
						$resuming = 0;
						close $fh;
						main::logger "WARNING: Resize incorrect for file: $file_tmp\n";
						main::logger "WARNING: Expected: $resume_size Got: $trunc_size\n";
						main::logger "WARNING: Restarting download\n";
					}
				}
			}
		}
	}
	unlink $resume_file unless $resuming;
	if ( $resuming ) {
		main::logger "INFO: Resume recording file: $file_tmp\n";
		main::logger sprintf("INFO: Resume recording at: %.2f MiB (%02d:%02d:%02d) [%d]\n",
			$resume_size / 1024.0 / 1024.0,
			(gmtime($resume_elapsed))[2,1,0],
			$resume_sequence
		);
	} else {
		# start download from beginning if not resuming
		if ( ! open($fh, ">:raw", $file_tmp) ) {
			main::logger "ERROR: Cannot open (write): $file_tmp\n";
			exit 1;
		}
		binmode $fh;
		$fh->autoflush(1);
		main::logger "INFO: Begin recording file: $file_tmp\n";
		main::logger sprintf("INFO: Begin recording at: %.2f MiB (%02d:%02d:%02d) [%d]\n",
			$size / 1024.0 / 1024.0,
			(gmtime($start_elapsed))[2,1,0],
			$start_sequence
		);
	}
	unless ( $noresume ) {
		my $open_mode = $resuming ? ">>" : ">";
		# open resume data file
		if ( ! open $rh, $open_mode, $resume_file ) {
			main::logger "ERROR: Cannot open (".($resuming ? "append" : "write")."): $resume_file\n";
			exit 1;
		}
		$rh->autoflush(1);
		unless ( $resuming ) {
			print $rh "#$resume_params\n";
		}
	}

	if ( defined $opt->{proxy} && $opt->{proxy} =~ /^prepend:/ ) {
		($proxy_prefix = $opt->{proxy}) =~ s/^prepend://g;
	}

	# process segments in playlist
	my @file_sequences = ($resume_sequence..$stop_sequence);
	if ( $size == 0 && defined $init_sequence ) {
		# ensure DASH init segment downloaded for new file
		unshift @file_sequences, $init_sequence;
	}
	my @warnings;
	for my $sequence ( @file_sequences ) {
		$curr_sequence = $sequence;
		my $segment = $segments->{$sequence};
		my $segment_duration = $segment->{duration};
		$elapsed += $segment_duration;
		my $segment_url;
		# proxy url
		if ( $proxy_prefix ) {
			$segment_url = $proxy_prefix.main::url_encode( $segment->{url} );
		} else {
			$segment_url = $segment->{url};
		}
		$curr_segment_url = $segment_url;
		main::logger "\nDEBUG: Downloading file segment [$sequence]\n" if $opt->{debug};
		main::logger "DEBUG: File segment URL: $segment_url\n" if $opt->{debug};;
		# download segment with retries
		my $expected = 0;
		my $got404 = 0;
		my $i;
		for ($i = 0; $i < $retries; $i++) {
			my $res = $ua->get($segment_url, ':content_cb' => $callback);
			$expected = $res->header("Content-Length");
			if ( ! $res->is_success || ! $res->header("Content-Length") ) {
				if ( $res->code == 404 ) {
					if ( $sequence == $max_sequence ) {
						# potential edge cases with incorrect DASH manifests
						main::logger "\nWARNING: File segment not available from server [$sequence]\n";
						main::logger "WARNING: This is the final file segment of the programme\n";
						main::logger "WARNING: It may be incorrectly flagged as unavailable due to inaccurate programme data\n";
						main::logger "WARNING: Check the end of the recording to ensure it is complete\n";
						if ( $opt->{verbose} ) {
							main::logger "WARNING: File segment URL: $curr_segment_url\n";
						}
					} else {
						# don't retry if 404 received
						@warnings = ("File segment not available from server [$sequence]");
						$return = 2;
					}
					$got404 = 1;
					last;
				}
			} else {
				last;
			}
		}
		# bail out if not available
		last if $got404;
		# bail out on download failure
		if ( $i == $retries ) {
			@warnings = ("Failed to download file segment [$sequence]");
			$return = 1;
			last;
		}
		my $size_diff = $size - $prev_size;
		# verify segment size
		unless ( $opt->{noverify} ) {
			if ( $size_diff != $expected) {
				close $rh unless $noresume;
				@warnings = (
					"Unexpected size for file segment [$sequence]",
					"Expected: $expected  Downloaded: $size_diff",
					"Retrying download"
				);
				$return = 1;
				last;
			}
		}
		# capture resume data
		unless ( $noresume ) {
			if ( ! print $rh "$sequence,$size,$elapsed,$size_diff,$segment_duration,$begin_time\n" ) {
				close $rh;
				@warnings = (
					"Unable to save resume data for file segment [$sequence]",
					"Retrying download"
				);
				$return = 1;
				last;
			}
		}
		$prev_sequence = $sequence;
		$prev_size = $size;
		$prev_elapsed = $elapsed;
	}
	close $fh;
	close $rh unless $noresume;

	# summary stats
	unless ( $hide_progress || $opt->{logprogress} ) {
		main::logger "${crlf}".(" " x ($opt->{verbose} ? 120 : 80));
	}
	my $end_time = time() + 0.0001;
	main::logger sprintf("${crlf}INFO: Recorded: %.2f MiB (%02d:%02d:%02d) [%d] in %02d:%02d:%02d at %.2f Mibit/s\n",
		($prev_size - $resume_size) / (1024.0 * 1024.0),
		(gmtime($prev_elapsed - $resume_elapsed))[2,1,0],
		max($prev_sequence - $resume_sequence + 1, 0),
		(gmtime($end_time - $begin_time))[2,1,0],
		($prev_size - $resume_size) / ($end_time - $begin_time) / 1024.0 / 1024.0 * 8.0,
	);

	# retry if we fail during streaming
	if ( $return ) {
		main::logger "WARNING: ".(join "\nWARNING: ", @warnings)."\n" if @warnings;
		main::logger "WARNING: Stopped recording file: $file_tmp\n";
		main::logger sprintf("WARNING: Stopped recording at: %.2f MiB (%02d:%02d:%02d) [%d]\n",
			$prev_size / 1024.0 / 1024.0,
			(gmtime($prev_elapsed))[2,1,0],
			$prev_sequence
		);
		if ( $opt->{verbose} ) {
			main::logger "WARNING: File segment URL: $curr_segment_url\n";
		}
		return $return > 1 ? 'next' : 'retry';
	}

	# clear resume data
	unlink $resume_file;

	if ( $resuming ) {
		# summary for file
		main::logger sprintf("INFO: Recorded (total): %.2f MiB (%02d:%02d:%02d) [%d]\n",
			$prev_size / (1024.0 * 1024.0),
			(gmtime($prev_elapsed - $start_elapsed))[2,1,0],
			$prev_sequence - $start_sequence + 1
		);
	}

	return 0;
}


################### Streamer::dash class #################
package Streamer::dash;

use base 'Streamer::hls';
use File::Basename;
use File::Copy;
use File::stat;
use List::Util qw(max);
use strict;

sub generate_segments {
	my ($self, $media ) = @_;
	return undef if ! $media;
	my $segments;
	for my $sequence ( $media->{start_number} .. $media->{stop_number} ) {
		my $segment_url;
		if ( $sequence == $media->{start_number} ) {
			($segment_url = $media->{init_template}) =~ s/\$RepresentationID\$/$media->{id}/;
			$segments->{$sequence - 1} = { 'url' => $segment_url, 'duration' => 0, 'initialization' => 1 };
		}
		($segment_url = $media->{media_template}) =~ s/\$RepresentationID\$/$media->{id}/;
		$segment_url =~ s/\$Number\$/$sequence/;
		$segments->{$sequence} = { 'url' => $segment_url, 'duration' => $media->{segment_duration} };
	}
	return $segments;
}

sub get {
	my ( $self, $ua, $url, $prog, %streamdata ) = @_;
	my $rc;

	# audio files
	my $audio_prefix = $prog->{fileprefix};
	my $audio_tmp = main::encode_fs(File::Spec->catfile($prog->{dir}, "${audio_prefix}.audio.m4a"));
	my $audio_file = main::encode_fs(File::Spec->catfile($prog->{dir}, "${audio_prefix}.dash.m4a"));
	my $audio_raw = $prog->{type} eq "tv" ? $prog->{rawaudio} : $prog->{filename};

	# video files
	my $video_prefix = $prog->{fileprefix};
	my $video_tmp = main::encode_fs(File::Spec->catfile($prog->{dir}, "${video_prefix}.video.m4v"));
	my $video_file = main::encode_fs(File::Spec->catfile($prog->{dir}, "${video_prefix}.dash.m4v"));
	my $video_raw = $prog->{rawvideo};

	if ( $opt->{overwrite} ) {
		main::logger "WARNING: Overwriting DASH audio file: $audio_file\n" if -f $audio_file;
		main::logger "WARNING: Overwriting DASH video file: $video_file\n" if $prog->{type} eq "tv" && -f $video_file;
		unlink ( $audio_file, $video_file );
	} else {
		my $skip;
		if ( -f $audio_file ) {
			main::logger "WARNING: Using existing DASH audio file: $audio_file\n";
			$skip = 1;
		}
		if ( $prog->{type} eq "tv" && -f $video_file ) {
			main::logger "WARNING: Using existing DASH video file: $video_file\n";
			$skip = 1;
		}
		if ( $skip ) {
			main::logger "WARNING: Use --overwrite to re-download\n";
		}
	}

	unless ( -f $audio_file ) {
		my $audio_media = $streamdata{audio_media};
		$streamdata{file_size} = $audio_media->{file_size};
		$streamdata{media_bitrate} = $audio_media->{bitrate};
		my $segments = $self->generate_segments($audio_media);
		if ( keys %{$segments} <= 1 ) {
			main::logger "ERROR: No file segments generated from DASH audio media\n";
			return 'next';
		}
		$rc = $self->fetch( $ua, $segments, $audio_tmp, $prog, %streamdata );
		return $rc if $rc;
		if ( ! move($audio_tmp, $audio_file) ) {
			main::logger "ERROR: Could not rename file: $audio_tmp\n";
			main::logger "ERROR: Destination file name: $audio_file\n";
			return 'skip';
		}
		main::logger "INFO: Saved DASH audio file: $audio_file\n";
	}

	if ( $prog->{type} eq "tv" ) {
		unless ( -f $video_file ) {
			my $video_media = $streamdata{video_media};
			$streamdata{file_size} = $video_media->{file_size};
			$streamdata{media_bitrate} = $video_media->{bitrate};
			my $segments = $self->generate_segments($video_media);
			if ( keys %{$segments} <= 1 ) {
				main::logger "ERROR: No file segments generated from DASH video media\n";
				return 'next';
			}
			$rc = $self->fetch( $ua, $segments, $video_tmp, $prog, %streamdata );
			return $rc if $rc;
			if ( ! move($video_tmp, $video_file) ) {
				main::logger "ERROR: Could not rename file: $video_tmp\n";
				main::logger "ERROR: Destination file name: $video_file\n";
				return 'skip';
			}
			main::logger "INFO: Saved DASH video file: $video_file\n";
		}
	} else {
		unlink ( $video_tmp, $video_file );
	}

	if ( $opt->{raw} ) {
		if ( ! move($audio_file, $audio_raw) ) {
			main::logger "ERROR: Could not rename file: $audio_file\n";
			main::logger "ERROR: Destination file name: $audio_raw\n";
			return 'skip';
		}
		if ( $prog->{type} eq "tv" ) {
			if ( ! move($video_file, $video_raw) ) {
				main::logger "ERROR: Could not rename file: $video_file\n";
				main::logger "ERROR: Destination file name: $video_raw\n";
				return 'skip';
			}
		}
		main::logger "INFO: Recorded raw audio file: $audio_raw\n";
		main::logger "INFO: Recorded raw video file: $video_raw\n" if $prog->{type} eq "tv";
		return 0;
	}

	return $self->remux($audio_file, $video_file, $prog, %streamdata);
}


############# PVR Class ##############
package Pvr;

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use IO::Seekable;
use IO::Socket;
use strict;
use Time::Local;

# Class vars
my %vars = {};
# Global options
my $optref;
my $opt_fileref;
my $opt_cmdlineref;
my $opt;
my $opt_file;
my $opt_cmdline;

# Class cmdline Options
sub opt_format {
	return {
		pvr		=> [ 0, "pvr|pvrrun|pvr-run!", 'PVR', '--pvr [pvr search name]', "Runs the PVR using all saved PVR searches (intended to be run every hour from cron etc). The list can be limited by adding a regex to the command. Synonyms: --pvrrun, --pvr-run"],
		pvrexclude	=> [ 0, "pvrexclude|pvr-exclude=s", 'PVR', '--pvr-exclude <string>', "Exclude the PVR searches to run by search name (comma-separated regex list). Defaults to substring match. Synonyms: --pvrexclude"],
		pvrsingle	=> [ 0, "pvrsingle|pvr-single=s", 'PVR', '--pvr-single <search name>', "Runs a named PVR search. Synonyms: --pvrsingle"],
		pvradd		=> [ 0, "pvradd|pvr-add=s", 'PVR', '--pvr-add <search name>', "Save the named PVR search with the specified search terms. Search terms required unless --pid specified. Synonyms: --pvradd"],
		pvrdel		=> [ 0, "pvrdel|pvr-del=s", 'PVR', '--pvr-del <search name>', "Remove the named search from the PVR searches. Synonyms: --pvrdel"],
		pvrdisable	=> [ 1, "pvrdisable|pvr-disable=s", 'PVR', '--pvr-disable <search name>', "Disable (not delete) a named PVR search. Synonyms: --pvrdisable"],
		pvrenable	=> [ 1, "pvrenable|pvr-enable=s", 'PVR', '--pvr-enable <search name>', "Enable a previously disabled named PVR search. Synonyms: --pvrenable"],
		pvrlist		=> [ 0, "pvrlist|pvr-list!", 'PVR', '--pvr-list', "Show the PVR search list. Synonyms: --pvrlist"],
		pvrqueue	=> [ 0, "pvrqueue|pvr-queue!", 'PVR', '--pvr-queue', "Add currently matched programmes to queue for later one-off recording using the --pvr option. Search terms required unless --pid specified. Synonyms: --pvrqueue"],
		pvrscheduler	=> [ 0, "pvrscheduler|pvr-scheduler=n", 'PVR', '--pvr-scheduler <seconds>', "Runs the PVR using all saved PVR searches every <seconds>. Synonyms: --pvrscheduler"],
		comment		=> [ 1, "comment=s", 'PVR', '--comment <string>', "Adds a comment to a PVR search"],
	};
}


# Constructor
# Usage: $pvr = Pvr->new();
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	## Ensure the subclass $opt var is pointing to the Superclass global optref
	$opt = $Pvr::optref;
	$opt_file = $Pvr::opt_fileref;
	$opt_cmdline = $Pvr::opt_cmdlineref;
	bless $self, $type;
}


# Use to bind a new options ref to the class global $opt_ref var
sub add_opt_object {
	my $self = shift;
	$Pvr::optref = shift;
}
# Use to bind a new options ref to the class global $opt_fileref var
sub add_opt_file_object {
	my $self = shift;
	$Pvr::opt_fileref = shift;
}
# Use to bind a new options ref to the class global $opt_cmdlineref var
sub add_opt_cmdline_object {
	my $self = shift;
	$Pvr::opt_cmdlineref = shift;
}


# Use to bind a new options ref to the class global $optref var
sub setvar {
	my $self = shift;
	my $varname = shift;
	my $value = shift;
	$vars{$varname} = $value;
}
sub getvar {
	my $self = shift;
	my $varname = shift;
	return $vars{$varname};
}


# $opt->{<option>} access method
sub opt {
	my $self = shift;
	my $optname = shift;
	return $opt->{$optname};
}


# Load all PVR searches and run one-by-one
# Usage: $pvr->run( [pvr search name] )
sub run {
	my $pvr = shift;
	my $pvr_name_regex = shift || '.*';
	my $exclude_regex = '_ROUGE_VALUE_';

	# Don't attempt to record programmes with pids in history
	my $hist = History->new();

	# Load all PVR searches
	$pvr->load_list();

	if ( $opt->{pvrexclude} ) {
		$exclude_regex = '('.(join '|', ( split /,/, $opt->{pvrexclude} ) ).')';
	}

	# For each PVR search (or single one if specified)
	my @names = ( grep !/$exclude_regex/i, grep /$pvr_name_regex/i, sort {lc $a cmp lc $b} keys %{$pvr} );

	my $retcode = 0;
	main::logger "Running PVR Searches:\n";
	for my $name ( @names ) {
		# Ignore if this search is disabled
		if ( $pvr->{$name}->{disable} ) {
			main::logger "\nSkipping '$name' (disabled)\n" if $opt->{verbose};
			next;
		}
		main::logger "$name\n";
		# Clear then Load options for specified pvr search name
		my $opt_backup;
		foreach ( @encoding_opts ) {
			$opt_backup->{$_} = $opt->{$_} if $opt->{$_};
		}
		my @search_args = $pvr->load_options($name);
		foreach ( @encoding_opts ) {
			$opt->{$_} = $opt_backup->{$_} if $opt_backup->{$_};
		}

		## Display all options used for this pvr search
		#$opt->display('Default Options', '(help|debug|get|^pvr)');

		# Switch on --hide option
		$opt->{hide} = 1;
		# Switch off --future option (no point in checking future programmes)
		$opt->{future} = '';
		# Dont allow --refresh with --pvr
		$opt->{refresh} = '';
		# Don't allow --info with --pvr
		$opt->{info} = '';
		# Do the recording (force --get option)
		$opt->{get} = 1 if ! $opt->{test};

		my $failcount = 0;
		if ( $pvr->{$name}->{pid} ) {
			my @pids = split( /,/, $pvr->{$name}->{pid} );
			for ( @pids ) {
				$opt->{pid} = $_;
				$failcount += main::find_pid_matches( $hist );
			}

		# Just make recordings of matching progs
		} else {
			$failcount = main::download_matches( $hist, main::find_matches( $hist, @search_args ) );
		}
		# If this is a one-off queue entry then delete the PVR entry upon successful recording(s)
		if ( $name =~ /^ONCE_/ ) {
			$pvr->del( $name ) if not $failcount;
		}
		if ( $failcount ) {
			main::logger "WARNING: PVR Run: $name: $failcount download failure(s)\n";
		}
		$retcode += $failcount
	}
	return $retcode;
}



sub run_scheduler {
	my $pvr = shift;
	my $interval = $opt->{pvrscheduler};
	# Ensure the caches refresh every run (assume cache refreshes take at most 300 seconds)
	$opt_cmdline->{expiry} = $interval - 300;
	main::logger "INFO: Scheduling the PVR to run every $interval secs\n";
	while ( 1 ) {
		my $start_time = time();
		$opt_cmdline->{pvr} = 1;
		# empty mem cache before each run to force cache file refresh
		for ( keys %$memcache ) {
			delete $memcache->{$_};
		}
		my $retcode = $pvr->run();
		if ( $retcode ) {
			main::logger "WARNING: PVR Scheduler: ".localtime().": $retcode download failure(s) \n";
		}
		my $remaining = $interval - ( time() - $start_time );
		if ( $remaining > 0 ) {
			main::logger "INFO: Sleeping for $remaining secs\n";
			sleep $remaining;
		}
	}
}



# If queuing, only add pids because the index number might change by the time the pvr runs
# If --pid and --type <type> is specified then add this prog also
sub queue {
	my $pvr = shift;
	my @search_args = @_;

	# Switch on --hide option
	$opt->{hide} = 1;
	my $hist = History->new();

	# PID and TYPE specified
	if ( $opt_cmdline->{pid} ) {
		# ensure we only have one prog type defined (or none)
		if ( $opt_cmdline->{type} !~ /,/ ) {
			# Add to PVR if not already in history
			$pvr->add( "ONCE_$opt_cmdline->{pid}" ) if ( ! $hist->check( $opt_cmdline->{pid} ) );
		} else {
			main::logger "ERROR: Cannot add a pid to the PVR queue without a single --type specified\n";
			return 1;
		}

	# Search specified
	} else {
		my @matches = main::find_matches( $hist, @search_args );
		# Add a PVR entry for each matching prog PID
		for my $this ( @matches ) {
			$opt_cmdline->{pid} = $this->{pid};
			$opt_cmdline->{type} = $this->{type};
			$pvr->add( $this->substitute('ONCE_<name> - <episode> <pid>') );
		}

	}
	return 0;
}



# Save the options on the cmdline as a PVR search with the specified name
sub add {
	my $pvr = shift;
	my $name = shift;
	my @search_args = @_;
	my @options;
	# validate name
	if ( $name !~ m{[\w\-\+]+} ) {
		main::logger "ERROR: Invalid PVR search name '$name'\n";
		return 1;
	}
	# Parse valid options and create array (ignore options from the options files that have not been overriden on the cmdline)
	for ( grep !/(^cache|profiledir|encoding.*|silent|webrequest|future|nocopyright|^test|metadataonly|subsonly|thumbonly|tagonly|^get|refresh|^save|^prefs|help|expiry|tree|terse|streaminfo|listformat|^list|showoptions|hide|info|pvr.*)$/, sort {lc $a cmp lc $b} keys %{$opt_cmdline} ) {
		if ( defined $opt_cmdline->{$_} ) {
				push @options, "$_ $opt_cmdline->{$_}";
				main::logger "DEBUG: Adding option $_ = $opt_cmdline->{$_}\n" if $opt->{debug};
		}
	}
	# Add search args to array
	for ( my $count = 0; $count <= $#search_args; $count++ ) {
		push @options, "search${count} $search_args[$count]";
		main::logger "DEBUG: Adding search${count} = $search_args[$count]\n" if $opt->{debug};
	}
	# Save search to file
	$pvr->save( $name, @options );
	return 0;
}



# Delete the named PVR search
sub del {
	my $pvr = shift;
	my $name = shift;
	# validate name
	if ( $name !~ m{[\w\-\+]+} ) {
		main::logger "ERROR: Invalid PVR search name '$name'\n";
		return 1;
	}
	# Delete pvr search file
	if ( -f $vars{pvr_dir}.$name ) {
		unlink $vars{pvr_dir}.$name;
		main::logger "INFO: Deleted PVR search '$name'\n";
	} else {
		main::logger "ERROR: PVR search '$name' does not exist\n";
		return 1;
	}
	return 0;
}



# Display all the PVR searches
sub display_list {
	my $pvr = shift;
	# Load all the PVR searches
	$pvr->load_list();
	# Print out list
	main::logger "All PVR Searches:\n\n";
	for my $name ( sort {lc $a cmp lc $b} keys %{$pvr} ) {
		# Report whether disabled
		if ( $pvr->{$name}->{disable} ) {
			main::logger "pvrsearch = $name (disabled)\n";
		} else {
			main::logger "pvrsearch = $name\n";
		}
		for ( sort keys %{ $pvr->{$name} } ) {
			main::logger "\t$_ = $pvr->{$name}->{$_}\n";
		}
		main::logger "\n";
	}
	return 0;
}



# Load all the PVR searches into %{$pvr}
sub load_list {
	my $pvr = shift;
	# Clear any previous data in $pvr
	$pvr->clear_list();
	# Make dir if not existing
	mkpath $vars{pvr_dir} if ! -d $vars{pvr_dir};
	# Get list of files in pvr_dir
	# open file with handle DIR
	opendir( DIR, $vars{pvr_dir} );
	if ( ! opendir( DIR, $vars{pvr_dir}) ) {
		main::logger "ERROR: Cannot open directory $vars{pvr_dir}\n";
		return 1;
	}
	# Get contents of directory (ignoring . .. and ~ files)
	my @files = grep ! /(^\.{1,2}$|^.*~$)/, readdir DIR;
	# Close the directory
	closedir DIR;
	# process each file
	for my $file (@files) {
		chomp($file);
		# Re-add the dir
		$file = "$vars{pvr_dir}/$file";
		next if ! -f $file;
		if ( ! open (PVR, "< $file") ) {
			main::logger "WARNING: Cannot read PVR search file $file\n";
			next;
		}
		my @options = <PVR>;
		close PVR;
		# Get search name from filename
		my $name = $file;
		$name =~ s/^.*\/([^\/]+?)$/$1/g;
		for (@options) {
			/^\s*([\w\-_]+?)\s+(.*)\s*$/;
			main::logger "DEBUG: PVR search '$name': option $1 = $2\n" if $opt->{debug};
			$pvr->{$name}->{$1} = $2;
		}
		main::logger "INFO: Loaded PVR search '$name'\n" if $opt->{verbose};
	}
	main::logger "INFO: Loaded PVR search list\n" if $opt->{verbose};
	return 0;
}



# Clear all the PVR searches in %{$pvr}
sub clear_list {
	my $pvr = shift;
	# There is probably a faster way
	delete $pvr->{$_} for keys %{ $pvr };
	return 0;
}



# Save the array options specified as a PVR search
sub save {
	my $pvr = shift;
	my $name = shift;
	my @options = @_;
	# Sanitize name
	$name = StringUtils::sanitize_path( $name, 0, 1 );
	# Make dir if not existing
	mkpath $vars{pvr_dir} if ! -d $vars{pvr_dir};
	main::logger "INFO: Saving PVR search '$name':\n";
	# Open file
	if ( ! open (PVR, "> $vars{pvr_dir}/${name}") ) {
		main::logger "ERROR: Cannot save PVR search to $vars{pvr_dir}.$name\n";
		return 1;
	}
	# Write options array to file
	for (@options) {
		print PVR "$_\n";
		main::logger "\t$_\n";
	}
	close PVR;
	return 0;
}


# Uses globals: $profile_dir, $optfile_system, $optfile_default
# Uses class globals: %opt, %opt_file, %opt_cmdline
# Returns @search_args
# Clear all exisiting global args and opts then load the options specified in the default options and specified PVR search
sub load_options {
	my $pvr = shift;
	my $name = shift;

	my $optfile_preset;
	# reset proxy env var
	$ENV{http_proxy} = $ENV_HTTP_PROXY;
	# Clear out existing options and file options hashes
	%{$opt} = ();

	# If the preset option is used in the PVR search then use it.
	if ( $pvr->{$name}->{preset} ) {
		$optfile_preset = ${profile_dir}."/presets/".$pvr->{$name}->{preset};
		main::logger "DEBUG: Using preset file: $optfile_preset\n" if $opt_cmdline->{debug};
	}

	# Re-copy options read from files at start of whole run
	$opt->copy_set_options_from( $opt_file );

	# Load options from $optfile_preset into $opt (uses $opt_cmdline as readonly options for debug/verbose etc)
	$opt->load( $opt_cmdline, $optfile_preset );

	# Clear search args
	@search_args = ();
	# Set each option from the search
	for ( sort {$a cmp $b} keys %{ $pvr->{$name} } ) {
		# Add to list of search args if this is not an option
		if ( /^search\d+$/ ) {
			main::logger "INFO: $_ = $pvr->{$name}->{$_}\n" if $opt->{verbose};
			push @search_args, $pvr->{$name}->{$_};
		# Else populate options, ignore disable option
		} elsif ( $_ ne 'disable' ) {
			main::logger "INFO: Option: $_ = $pvr->{$name}->{$_}\n" if $opt->{verbose};
			$opt->{$_} = $pvr->{$name}->{$_};
		}
	}

	# Allow cmdline args to override those in the PVR search
	# Re-copy options from the cmdline
	$opt->copy_set_options_from( $opt_cmdline );
	return @search_args;
}



# Disable a PVR search by adding 'disable 1' option
sub disable {
	my $pvr = shift;
	my $name = shift;
	$pvr->load_list();
	my @options;
	for ( keys %{ $pvr->{$name} }) {
		push @options, "$_ $pvr->{$name}->{$_}";
	}
	# Add the disable option
	push @options, 'disable 1';
	$pvr->save( $name, @options );
	return 0;
}



# Re-enable a PVR search by removing 'disable 1' option
sub enable {
	my $pvr = shift;
	my $name = shift;
	$pvr->load_list();
	my @options;
	for ( keys %{ $pvr->{$name} }) {
		push @options, "$_ $pvr->{$name}->{$_}";
	}
	# Remove the disable option
	@options = grep !/^disable\s/, @options;
	$pvr->save( $name, @options );
	return 0;
}


package Tagger;
use Encode;
use File::stat;
use constant FB_EMPTY => sub { '' };

# already in scope
# my ($opt, $bin);
my $ap_check;

# constructor
sub new {
	my $class = shift;
	my $self = {};
	bless($self, $class);
}

# class command line options
sub opt_format {
	return {
		atomicparsley	=> [ 0, "atomicparsley|atomic-parsley=s", 'External Program', '--atomicparsley <path>', "Location of AtomicParsley binary"],
		noartwork => [ 1, "noartwork|no-artwork!", 'Tagging', '--no-artwork', "Do not embed thumbnail image in output file. Also removes existing artwork. All other metadata values will be written."],
		notag => [ 1, "notag|no-tag!", 'Tagging', '--no-tag', "Do not tag downloaded programmes. Note that moov atom will be at end of output file if --no-tag used. Remuxing would be necessary to stream file."],
		tag_formatshow		=> [ 1, "tagformatshow|tag-format-show=s", 'Tagging', '--tag-format-show', "Format template for programme name in tag metadata (use substitution parameters). Default: <name>"],
		tag_formattitle		=> [ 1, "tagformattitle|tag-format-title=s", 'Tagging', '--tag-format-title', "Format template for episode title in tag metadata (use substitution parameters). Default: <episodeshort>"],
		tag_isodate		=> [ 1, "tagisodate|tag-isodate!", 'Tagging', '--tag-isodate', "Use ISO8601 dates (YYYY-MM-DD) in album/show names and track titles"],
		tag_podcast => [ 1, "tagpodcast|tag-podcast!", 'Tagging', '--tag-podcast', "Tag downloaded radio and tv programmes as iTunes podcasts"],
		tag_podcast_radio => [ 1, "tagpodcastradio|tag-podcast-radio!", 'Tagging', '--tag-podcast-radio', "Tag only downloaded radio programmes as iTunes podcasts"],
		tag_podcast_tv => [ 1, "tagpodcasttv|tag-podcast-tv!", 'Tagging', '--tag-podcast-tv', "Tag only downloaded tv programmes as iTunes podcasts"],
		tag_utf8 => [ 1, "tagutf8|tag-utf8!", 'Tagging', '--tag-utf8', "Use UTF-8 encoding for non-ASCII characters in AtomicParsley parameter values (Linux/Unix/macOS only). Use only if auto-detect fails."],
	};
}

# map metadata values to tags
sub tags_from_metadata {
	my ($self, $meta) = @_;
	my $tags;
	($tags->{title} = $meta->{title}) =~ s/[\s\-]+$//;
	$tags->{title} ||= $meta->{show};
	# iTunes media kind
	$tags->{stik} = 'Normal';
	if ( $meta->{ext} =~ /(mp4|m4v)/i) {
		$tags->{stik} = $meta->{categories} =~ /(film|movie)/i ? 'Short Film' : 'TV Show';
	}
	$tags->{advisory} = $meta->{guidance} ? 'explicit' : 'remove';
	# copyright message from download date
	$tags->{copyright} = substr($meta->{dldate}, 0, 4)." British Broadcasting Corporation, all rights reserved";
	$tags->{artist} = $meta->{channel};
	# album artist from programme type
	($tags->{albumArtist} = "BBC " . ucfirst($meta->{type})) =~ s/tv/TV/i;
	$tags->{album} = $meta->{show};
	$tags->{grouping} = $meta->{categories};
	# composer references iPlayer
	$tags->{composer} = "BBC iPlayer";
	# extract genre as first category, use second if first too generic
	$tags->{genre} = $meta->{category};
	$tags->{comment} = $meta->{descshort};
	# fix up firstbcast if necessary
	$tags->{year} = $meta->{firstbcast};
	if ( $tags->{year} !~ /\d{4}-\d{2}-\d{2}\D\d{2}:\d{2}:\d{2}/ ) {
		my @utc = gmtime();
		$utc[4] += 1;
		$utc[5] += 1900;
		$tags->{year} = sprintf("%4d-%02d-%02dT%02d:%02d:%02dZ", reverse @utc[0..5]);
	}
	$tags->{tracknum} = $meta->{episodenum};
	$tags->{disk} = $meta->{seriesnum};
	# generate lyrics text with links if available
	$tags->{lyrics} = $meta->{desclong};
	$tags->{lyrics} .= "\n\nEPISODE\n$meta->{player}" if $meta->{player};
	$tags->{lyrics} .= "\n\nSERIES\n$meta->{web}" if $meta->{web};
	$tags->{description} = $meta->{descshort};
	$tags->{longDescription} = $meta->{desclong};
	$tags->{hdvideo} = $meta->{mode} =~ /hd/i ? 'true' : 'false';
	$tags->{TVShowName} = $meta->{show};
	$tags->{TVEpisode} = $meta->{senum} ? $meta->{senum} : $meta->{pid};
	$tags->{TVSeasonNum} = $tags->{disk};
	$tags->{TVEpisodeNum} = $tags->{tracknum};
	$tags->{TVNetwork} = $meta->{channel};
	$tags->{podcastFlag} = 'true';
	$tags->{category} = $tags->{genre};
	$tags->{keyword} = $meta->{categories};
	$tags->{podcastGUID} = $meta->{player};
	$tags->{artwork} = $meta->{thumbfile};
	# video flag
	$tags->{is_video} = $meta->{ext} =~ /(mp4|m4v)/i;
	# tvshow flag
	$tags->{is_tvshow} = $tags->{stik} eq 'TV Show';
	# podcast flag
	$tags->{is_podcast} = $opt->{tag_podcast}
		|| ( $opt->{tag_podcast_radio} && ! $tags->{is_video} )
		|| ( $opt->{tag_podcast_tv} && $tags->{is_video} );
	$tags->{pid} = $meta->{pid};
	if ( $opt->{tag_isodate} ) {
		for my $field ( 'title', 'album', 'TVShowName' ) {
			$tags->{$field} =~ s|(\d\d)[/_](\d\d)[/_](20\d\d)|$3-$2-$1|g;
		}
	}
	while ( my ($key, $val) = each %{$tags} ) {
		$tags->{$key} = StringUtils::convert_punctuation($val);
	}
	return $tags;
}

# in-place escape/enclose embedded quotes in command line parameters
sub tags_escape_quotes {
	my ($tags) = @_;
	# only necessary for Windows
	if ( $^O =~ /^MSWin32$/ ) {
		while ( my ($key, $val) = each %$tags ) {
			if ($val =~ /"/) {
				$val =~ s/"/\\"/g;
				$tags->{$key} = '"'.$val.'"';
			}
		}
	}
}

# in-place encode metadata values to iso-8859-1
sub tags_encode {
	my ($tags) = @_;
	while ( my ($key, $val) = each %{$tags} ) {
		$tags->{$key} = encode("iso-8859-1", $val, FB_EMPTY);
	}
}

# add metadata tag to programme
sub tag_prog {
	my ($self, $prog) = @_;
	# create metadata for tagging
	my $meta;
	while ( my ($key, $val) = each %{$prog} ) {
		if ( ref($val) eq 'HASH' ) {
			$meta->{$key} = $prog->{$key}->{$prog->{version}};
		} else {
			$meta->{$key} = $val;
		}
	}
	my $fmt_show = $opt->{tag_formatshow} || "<name>";
	my $fmt_title = $opt->{tag_formattitle} || "<episodeshort>";
	$meta->{show} = $prog->substitute($fmt_show, 99);
	$meta->{title} = $prog->substitute($fmt_title, 99);
	my $tags = $self->tags_from_metadata($meta);
	if ( $meta->{filename} =~ /\.(mp4|m4v|m4a)$/i ) {
		return $self->tag_file_mp4($meta, $tags);
	} else {
		main::logger "WARNING: Don't know how to tag \U$meta->{ext}\E file\n" if $opt->{verbose};
	}
}

# add MP4 tag with atomicparsley
sub tag_file_mp4 {
	my ($self, $meta, $tags) = @_;
	# Only tag if the required tool exists
	if ( main::exists_in_path( 'atomicparsley' ) ) {
		if ( ! $ap_check ) {
			# determine AtomicParsley features
			$ap_check = 1;
			my $ap_help = `"$bin->{atomicparsley}" --help 2>&1`;
			$opt->{tag_hdvideo} = 1 if $ap_help =~ /--hdvideo/;
			$opt->{tag_longdesc} = 1 if $ap_help =~ /--longdesc/;
			$opt->{tag_longdescription} = 1 if $ap_help =~ /--longDescription/;
			$opt->{tag_utf8} = 1 if ! defined($opt->{tag_utf8}) and ( $^O ne "MSWin32" or $bin->{atomicparsley} =~ /-utf8/i );
		}
		main::logger "INFO: Begin tagging file: $meta->{filename}\n";
		# handle embedded quotes
		tags_escape_quotes($tags);
		# encode metadata for atomicparsley
		tags_encode($tags) unless $opt->{tag_utf8};
		# build atomicparsley command
		my @cmd = (
			$bin->{atomicparsley},
			$meta->{filename},
			'--freefree',
			'--overWrite',
			'--stik', $tags->{stik},
			'--advisory', $tags->{advisory},
			'--copyright', $tags->{copyright},
			'--title', $tags->{title},
			'--artist', $tags->{artist},
			'--albumArtist', $tags->{albumArtist},
			'--album', $tags->{album},
			'--grouping', $tags->{grouping},
			'--composer', $tags->{composer},
			'--genre', $tags->{genre},
			'--comment', $tags->{comment},
			'--year', $tags->{year},
			'--tracknum', $tags->{tracknum},
			'--disk', $tags->{disk},
			'--lyrics', $tags->{lyrics},
		);
		# add descriptions to audio podcasts and video
		if ( $tags->{is_video} || $tags->{is_podcast}) {
			push @cmd, ('--description', $tags->{description} );
			if ( $opt->{tag_longdescription} ) {
				push @cmd, ( '--longDescription', $tags->{longDescription} );
			} elsif ( $opt->{tag_longdesc} ) {
				push @cmd, ( '--longdesc', $tags->{longDescription} );
			}
		}
		# video only
		if ( $tags->{is_video} ) {
			# all video
			push @cmd, ( '--hdvideo', $tags->{hdvideo} ) if $opt->{tag_hdvideo};
			# tv only
			if ( $tags->{is_tvshow} ) {
				push @cmd, (
					'--TVShowName', $tags->{TVShowName},
					'--TVEpisode', $tags->{TVEpisode},
					'--TVSeasonNum', $tags->{TVSeasonNum},
					'--TVEpisodeNum', $tags->{TVEpisodeNum},
					'--TVNetwork', $tags->{TVNetwork},
				);
			}
		}
		# tag iTunes podcast
		if ( $tags->{is_podcast} ) {
			push @cmd, (
				'--podcastFlag', $tags->{podcastFlag},
				'--category', $tags->{category},
				'--keyword', $tags->{keyword},
				'--podcastGUID', $tags->{podcastGUID},
			);
		}
		# add artwork if available
		if ( $opt->{noartwork} ) {
			push @cmd, ( '--artwork', "REMOVE_ALL" );
		} else {
			push @cmd, ( '--artwork', $meta->{thumbfile} ) if -f $meta->{thumbfile};
		}
		# run atomicparsley command
		my $run_mode = main::hide_progress() ? 'QUIET_STDOUT' : 'STDERR';
		if ( main::run_cmd( $run_mode, @cmd ) ) {
			main::logger "WARNING: Failed to tag \U$meta->{ext}\E file\n";
			return 2;
		}
		# remove images left behind by AtomicParsley
		unlink glob qq("$meta->{dir}/$meta->{fileprefix}-resized-*");
		main::logger "INFO: Tagged file: $meta->{filename}\n";
	} else {
		main::logger "WARNING: Cannot tag \U$meta->{ext}\E file\n" if $opt->{verbose};
	}
}

############## End OO ##############
