package Slim::Web::Pages::Search;

# $Id$

# Logitech Media Server Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

use Date::Parse qw(str2time);
use File::Spec::Functions qw(:ALL);
use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(blessed);
use Storable;

use Slim::Music::VirtualLibraries;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::Pages;

use constant MAX_ADV_RESULTS => 200;

my $log = logger('network.http');
my $prefs = preferences('advancedSearch');

sub init {
	
	Slim::Web::Pages->addPageFunction( qr/^search\.(?:htm|xml)/, \&search );
	Slim::Web::Pages->addPageFunction( qr/^advanced_search\.(?:htm|xml)/, \&advancedSearch );
	
	Slim::Web::Pages->addPageLinks("search", {'ADVANCEDSEARCH' => "advanced_search.html"});
	
	# register saved searches as virtual libraries
	foreach my $vlid ( @{_getLibraryViews()} ) {
		my $vl = $prefs->get($vlid);
		Slim::Music::VirtualLibraries->registerLibrary( {
			id => $vlid,
			name => $vl->{name},
			# %s is being replaced with the library's internal ID
			sql => "INSERT OR IGNORE INTO library_track (library, track) " . $vl->{sql},
			unregisterCB => \&_removeLibraryView,
		} );
	}
}

use constant MAXRESULTS => 10;

sub search {
	my ($client, $params) = @_;

	my $library_id = '';
	if ( $library_id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client) ) {
		$params->{'library_id'} ||= $library_id;
		$library_id = "&library_id=$library_id";
	}
	
	if (my $action = $params->{'action'}) {
		$params->{'path'} = "clixmlbrowser/clicmd=browselibrary+playlist+$action&mode=search$library_id/";
		return Slim::Web::XMLBrowser::webLink(@_);
	}

	
	if ($params->{'ajaxSearch'}) {
		$params->{'itemsPerPage'} = MAXRESULTS;
		$params->{'path'} = "clixmlbrowser/clicmd=browselibrary+items&linktitle=SEARCH&mode=search$library_id/";
		return Slim::Web::XMLBrowser::webLink(@_);		
	}

	my $searchItems = Slim::Menu::BrowseLibrary::searchItems($client);
	
	$params->{searches} = [];
	
	foreach (@$searchItems) {
		push @{ $params->{searches} }, {
			$_->{name} => "search.html",
		};
	}

	return Slim::Web::HTTP::filltemplatefile('search.html', $params);	
}

sub advancedSearch {
	my ($client, $params) = @_;

	my $player  = $params->{'player'};
	my %query   = ();
	my @qstring = ();

	# template defaults
	$params->{'browse_list'}  = " ";
	$params->{'liveSearch'}   = 0;
	$params->{'browse_items'} = [];
	$params->{'icons'}        = $Slim::Web::Pages::additionalLinks{icons};
	
	if ( $params->{'action'} && $params->{'action'} eq 'deleteSaved' ) {
		$prefs->remove($params->{'savedSearch'});
		delete $params->{'deleteSavedSearch'};
		$params->{'resetAdvSearch'} = 1;
	}

	if ( $params->{'action'} && $params->{'action'} eq 'loadSaved' && $params->{'savedSearch'} && (my $searchParams = $prefs->get($params->{'savedSearch'})) ) {
		if (ref $searchParams eq 'HASH') {
			$params->{search} = Storable::dclone($searchParams);
			$params->{'resetAdvSearch'} = 1;
		}
	}
	elsif ( $params->{'resetAdvSearch'} ) {
		delete $params->{savedSearch};
	}
	
	# keep a copy of the search params to be stored in a saved search
	my %searchParams;

	# Check for valid search terms
	for my $key (sort keys %$params) {
		
		next unless $key =~ /^search\.(\S+)/;
		next unless $params->{$key};

		my $newKey = $1;

		if ($params->{'resetAdvSearch'}) {
			delete $params->{$key};
			next;
		}

		# Stuff the requested item back into the params hash, under
		# the special "search" hash. Because Template Toolkit uses '.'
		# as a delimiter for hash access.
		$params->{'search'}->{$newKey}->{'value'} = Slim::Utils::Unicode::utf8decode($params->{$key});

		# Apply the logical operator to the item in question.
		if ($key =~ /\.op$/) {

			my $op = $params->{$key};

			$key    =~ s/\.op$//;
			$newKey =~ s/\.op$//;

			$searchParams{$newKey} ||= {};
			$searchParams{$newKey}->{op} = $op; 

			next unless $params->{$key} || ($newKey eq 'year' && $params->{$key} eq '0');

			# Do the same for 'op's
			$params->{'search'}->{$newKey}->{'op'} = $params->{$key.'.op'};

			$newKey =~ s/_(rating|playcount)\b/\.$1/;

			# add these onto the query string. kinda jankey.
			push @qstring, join('=', "$key.op", $op);
			push @qstring, join('=', $key, $params->{$key});

			# Bitrate needs to changed a bit
			if ($key =~ /bitrate$/) {
				$params->{$key} *= 1000;
			}

			# Date Modified is also special
			if ($key =~ /timestamp$/) {
				$params->{$key} = str2time($params->{$key});
			}

			# BETWEEN values can be something like "1970-1990" but expects an arrayref
			if ($op =~ /BETWEEN/) {
				$params->{$key} = [ split(/[,\-: ]/, $params->{$key}), '', '' ];
				splice(@{$params->{$key}}, 2);
			}

			# Map the type to the query
			# This will be handed to SQL::Abstract
			$query{$newKey} = { $op => $params->{$key} };

			# don't include null/0 value years in search for earlier years
			# http://bugs.slimdevices.com/show_bug.cgi?id=5713
			if ($newKey eq 'year' && $op eq '<') {
				$query{$newKey}->{'>'} = '0';
			}

=pod Shall we treat an undefined rating the same as 0?
			if ($newKey eq 'persistent.rating' && $op eq '<') {
				$query{$newKey} = {
					'or' => [
						$newKey => { '=' => undef },
						$newKey => $query{$newKey},
					],
				};
			}
=cut

			delete $params->{$key};

			next;
		}
		elsif ($key =~ /search\.(.*)\.(active\d+)$/) {
			$searchParams{$1} ||= {};
			$searchParams{$1}->{$2} = $params->{$key}; 

			next;
		}

		$searchParams{$newKey} ||= {};
		$searchParams{$newKey}->{value} = $params->{$key}; 

		# Append to the query string
		push @qstring, join('=', $key, Slim::Utils::Misc::escape($params->{$key}));

		# Normalize the string queries
		# 
		# Turn the track_title into track.title for the query.
		# We need the _'s in the form, because . means hash key.
		if ($newKey =~ s/_(titlesearch|namesearch|value)$/\.$1/) {

			$params->{$key} = { 'like' => Slim::Utils::Text::searchStringSplit($params->{$key}) };
		}

		$newKey =~ s/_(rating|playcount)\b/\.$1/;

		# Wildcard searches
		if ($newKey =~ /lyrics/) {

			$params->{$key} = { 'like' => Slim::Utils::Text::searchStringSplit($params->{$key}) };
		}

		$query{$newKey} = $params->{$key};
	}

	if ( $params->{'action'} && $params->{'action'} eq 'saveSearch' && keys %searchParams && (my $saveSearch = $params->{saveSearch}) ) {
		# don't store operators when there's no value
		foreach my $k (keys %searchParams) {
			delete $searchParams{$k} unless $searchParams{$k}->{value};
		}
		$prefs->set($saveSearch, \%searchParams);
		
		delete $params->{saveSearch};
	}

	# XXX - need another way to get this list if not transcoding
	if (main::TRANSCODING) {
		# Turn our conversion list into a nice type => name hash.
		my %types  = ();
		
		for my $type (keys %{ Slim::Player::TranscodingHelper::Conversions() }) {
	
			$type = (split /-/, $type)[0];
			
			next if $type =~ /^(?:SPDR|TEST)$/i;
	
			$types{$type} = string($type);
		}
	
		$params->{'fileTypes'} = \%types;
	}
	
	# load up the genres we know about.
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	$params->{'genres'}     = Slim::Schema->search('Genre', undef, { 'order_by' => "namesort $collate" });
	$params->{'statistics'} = 1 if main::STATISTICS;
	$params->{'roles'}      = \%Slim::Schema::Contributor::roleToContributorMap;
	$params->{'searches'}   = _getSavedSearches();

	# short-circuit the query
	if (scalar keys %query == 0) {
		$params->{'numresults'} = -1;

		_initActiveRoles($params);

		return Slim::Web::HTTP::filltemplatefile("advanced_search.html", $params);
	}

	my @joins = ();
	_initActiveRoles($params);

	if ($query{'contributor.namesearch'}) {

		if (keys %{$params->{'search'}->{'contributor_namesearch'}}) {
			my @roles;
			foreach my $k (keys %{$params->{'search'}->{'contributor_namesearch'}}) {
				if ($k =~ /active(\d+)$/) {
					push @roles, $1;
				}
			}
			$query{'contributorTracks.role'} = \@roles if @roles;
		}

		if ($query{'contributor.namesearch'}) {

			push @joins, { 'contributorTracks' => 'contributor' };

		} else {

			push @joins, 'contributorTracks';
		}
	}

	# Pull in the required joins

	# create sub-query to get text based genre matches (if needed)
	my $namesearch = delete $query{'genre_name'};
	if ($query{'genre'}) {
		
		# IDs can change. When we want to save a library definition we better use the genre name.
		if ( $query{'genre'} >= 0 && $params->{'action'} && $params->{'action'} eq 'saveLibraryView' && (my $saveSearch = $params->{saveSearch}) ) {
			$namesearch = Slim::Schema->search('Genre', { id => $query{'genre'} })->get_column('name')->first;
			$query{'genre'} = { 
				'in' => Slim::Schema->search('Genre', {
					'me.namesearch' => { 'like' => Slim::Utils::Text::searchStringSplit($namesearch) }
				})->get_column('id')->as_query
			} if $namesearch;
		}

		if ($query{'genre'} < 0) {
			if ($namesearch) {
				my @tokens = map {
					s/^\s*//;
					s/\s+$//;
					@{Slim::Utils::Text::searchStringSplit($_)};
				} split /,/, $namesearch;
				
				$query{'genre'} = { 
					($query{'genre'} == -2 ? 'not_in' : 'in') => Slim::Schema->search('Genre', {
						'me.namesearch' => { 'like' => \@tokens }
					})->get_column('id')->as_query
				};
			}
			else {
				delete $query{'genre'};
			}
		}

		push @joins, 'genreTracks' if $query{'genre'} || $query{'genres.namesearch'};
	}

	if ($query{'album.titlesearch'}) {

		push @joins, 'album';
	}

	if ($query{'comments.value'}) {

		push @joins, 'comments';
	}
	
	if ( main::STATISTICS && $query{'persistent.rating'} || $query{'persistent.playcount'} ) {
		push @joins, 'persistent';
	}

	if ( my $library_id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client) ) {

		push @joins, 'libraryTracks';
		$query{'libraryTracks.library'} = $library_id;
	}

	# Disambiguate year
	if ($query{'year'}) {
		$query{'me.year'} = delete $query{'year'};
	}

	# XXXX - for some reason, the 'join' key isn't preserved when passed
	# along as a ref. Perl bug because 'join' is a keyword? Use 'joins' as well.
	my %attrs = (
		'order_by' => "me.disc, me.titlesort $collate",
		'join'     => \@joins,
		'joins'    => \@joins,
	);

	# Create a resultset - have fillInSearchResults do the actual search.
	my $rs  = Slim::Schema->search('Track', \%query, \%attrs)->distinct;

	if ( $params->{'action'} && $params->{'action'} eq 'saveLibraryView' && (my $saveSearch = $params->{saveSearch}) ) {
		my $sqlQuery = $rs->as_query;
		my $sql = $$sqlQuery->[0];
		#my $sqlParams = $$sqlQuery->[1];
		#	warn Data::Dump::dump($sqlQuery);
		
		# XXX - need some smarter way to interpolate variables in the query...
		for (my $i = 1; $i < scalar @{$$sqlQuery}; $i++) {
			my $v = $$sqlQuery->[$i]->[1];
			$v = "\"$v\"";
			$sql =~ s/ \? / $v /;
		}
		
		my $vlid = 'asvl_' . md5_hex($saveSearch);
		my $vl = {
			name => $saveSearch,
			sql  => "SELECT '%s', id FROM $sql",
		};
		
		$prefs->set($vlid, $vl);

		Slim::Music::VirtualLibraries->registerLibrary( {
			id => $vlid,
			name => $vl->{name},
			# %s is being replaced with the library's internal ID
			sql => "INSERT OR IGNORE INTO library_track (library, track) " . $vl->{sql},
			unregisterCB => \&_removeLibraryView,
		} );
		Slim::Music::VirtualLibraries->rebuild($vlid);
	}

	if (defined $client && !$params->{'start'}) {

		# stash parameters used to generate this query, so if the user
		# wants to play All Songs, we can run it again, but without
		# keeping all the tracks in memory twice.
		$client->modeParam('searchTrackResults', { 'cond' => \%query, 'attr' => \%attrs });
	}
	
	fillInSearchResults($params, $rs, \@qstring, 1, $client);

	return Slim::Web::HTTP::filltemplatefile("advanced_search.html", $params);
}

sub _initActiveRoles {
	my $params = shift;

	$params->{'search'} ||= {};
	$params->{'search'}->{'contributor_namesearch'} ||= {};

	foreach (keys %Slim::Schema::Contributor::roleToContributorMap) {
		$params->{'search'}->{'contributor_namesearch'}->{'active' . $_} = 1 if $params->{'search.contributor_namesearch.active' . $_};
	}

	$params->{'search'}->{'contributor_namesearch'} = { map { ('active' . $_) => 1 } @{ Slim::Schema->artistOnlyRoles } } unless keys %{$params->{'search'}->{'contributor_namesearch'}};
}

sub _removeLibraryView {
	my $id = shift;
	$prefs->remove($id);	
}

sub _getSavedSearches {
	return [ grep { $_ !~ /^asvl_[\da-f]+$/} keys %{$prefs->all} ];
}

sub _getLibraryViews {
	return [ grep /^asvl_[\da-f]+$/, keys %{$prefs->all} ];
}

sub fillInSearchResults {
	my ($params, $rs, $qstring, $advancedSearch, $client) = @_;

	my $player = $params->{'player'};
	my $query  = defined($params->{'query'}) ? $params->{'query'} : '';
	my $type   = lc($rs->result_source->source_name) || 'track';
	my $count  = $rs->count || return 0;

	# Set some reasonable defaults
	$params->{'numresults'}   = $count;
	$params->{'itemsPerPage'} ||= preferences('server')->get('itemsPerPage');

	# This is handed to pageInfo to generate the pagebar 1 2 3 >> links.
	my $otherParams = '&player=' . Slim::Utils::Misc::escape($player) . 
			  ($type ?'&type='. $type : '') . 
			  ($query ? '&query=' . Slim::Utils::Misc::escape($query) : '' ) . 
			  '&' .
			  join('&', @$qstring);

	# Put in the type separator
	if (!$advancedSearch && $count) {

		# add reduced item for type headings
		push @{$params->{'browse_items'}}, {
			'numresults' => $count,
			'query'      => $query,
			'heading'    => $type,
			'odd'        => 0,
		};
	}

	# Add in ALL
	if ($count > 1) {

		my $attributes = '';

		if ($advancedSearch) {
			$attributes = sprintf('&searchRef=search%sResults', ucfirst($type));
		} else {
			$attributes = sprintf('&%s.%s=%s', $type, $rs->searchColumn, $query);
		}

		push @{$params->{'browse_items'}}, {
			'text'       => string('ALL_SONGS'),
			'player'     => $params->{'player'},
			'attributes' => $attributes,
			'odd'        => 1,
		};
	}

	my $offset = ($params->{'start'} || 0);
	my $limit  = $offset + ($params->{'itemsPerPage'} || 50) - 1;

#	# No pagebar on advanced search - return more items instead, without killing the server with thousands of results
#	if (!$advancedSearch) {
		$params->{'pageinfo'} = Slim::Web::Pages::Common->pageInfo({
			'itemCount'    => $params->{'numresults'},
			'path'         => $params->{'path'},
			'otherParams'  => $otherParams,
			'start'        => $params->{'start'},
			'perPage'      => $params->{'itemsPerPage'},
		});

		$params->{'start'} = $params->{'pageinfo'}{'startitem'};
#	}
	
	# Get just the items we need for this loop.
	$rs = $rs->slice($offset, $limit);

	my $itemCount  = 0;
	my $descend    = $type eq 'track' ? 0 : 1;

	$params->{favoritesEnabled} = Slim::Utils::Favorites->enabled;
	my $favorites = $params->{favoritesEnabled} ? Slim::Utils::Favorites->new($client) : undef;

	# This is very similar to a loop in Slim::Web::Pages::BrowseDB....
	while (my $obj = $rs->next) {

		my %form = (
			'levelName'    => $type,
			'hreftype'     => 'browseDb',
			'descend'      => $descend,
			'odd'          => $itemCount % 2,
			'skinOverride' => $params->{'skinOverride'},
			'player'       => $params->{'player'},
			'itemobj'      => $obj,
			'level'        => 1,
			'searchResult' => 1,
		);

=pod
		if ($type eq 'contributor') {

			$form{'attributes'} .= '&contributor.role=ALL';
			$form{'hierarchy'}  = 'contributor,album,track';

		} elsif ($type eq 'album') {

			$form{'hierarchy'} = 'album,track';
		
		} elsif ($type eq 'genre') {
		
			$form{'hierarchy'} = 'genre,contributor,album,track';
		}
=cut

		if ($favorites && (my $url = $obj->url) ) {
			if (Slim::Music::Info::isURL($url)) {
				$form{'isFavorite'} = defined $favorites->findUrl($url);
			}
 		}

		$obj->displayAsHTML(\%form, $descend);
		
		$form{$type}        = $form{'item'};
		$form{'attributes'} = sprintf('&%s.id=%d', $type, $form{'item'});

		$itemCount++;

		push @{$params->{'browse_items'}}, \%form;
		
		main::idleStreams() unless $itemCount % 5;
	}
}

1;

__END__
