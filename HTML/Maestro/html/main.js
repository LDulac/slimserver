Main = function(){
	var layout;
	return {
		init : function(){
			Ext.UpdateManager.defaults.indicatorText = '<div class="loading-indicator">' + strings['loading'] + '</div>';

			layout = new Ext.BorderLayout('mainbody', {
				north: {
					split:false,
					initialSize: 45
				},
				south: {
					split:false,
					initialSize: 38
				},
				center: {
					autoScroll: false
				}
			});
			
			layout.beginUpdate();
			layout.add('north', new Ext.ContentPanel('header', {fitToFrame:true, fitContainer:true}));
			layout.add('south', new Ext.ContentPanel('footer', {fitToFrame:true, fitContainer:true}));
			layout.add('center', new Ext.ContentPanel('main', {fitToFrame:true, fitContainer:true}));

			Playlist.load();

			Ext.EventManager.onWindowResize(this.onResize, layout);
			Ext.EventManager.onDocumentReady(this.onResize, layout, true);

			layout.endUpdate();

			Ext.get('loading').hide();
			Ext.get('loading-mask').hide();
		},

		// resize panels, folder selectors etc.
		onResize : function(){
			dimensions = Ext.fly(document.body).getViewSize();
			Ext.get('mainbody').setHeight(dimensions.height-35);

			colWidth = Math.floor((dimensions.width - 168) / 2);

			left = Ext.get('leftcontent');
			left.setWidth(colWidth);
			left.setHeight(dimensions.height - 160);

			right = Ext.get('rightcontent');
			right.setWidth(colWidth);
			right.setHeight(dimensions.height-375);

			pl = Ext.get('playList');
			if (pl)
				pl.setHeight(dimensions.height-370 - pl.getTop() + right.getTop());

			Ext.get('rightpanel').setHeight(dimensions.height-365);

			this.layout();
		}
	};   
}();


Playlist = function(){
	return {
		load : function(){
			Ext.get('rightcontent').load(
				webroot + 'playlist.html',
				'playerid=' + player,
				this.onUpdated
			);
		},
		
		onUpdated : function(){
			colHeight = Ext.get('rightcontent').getHeight() + 5;
			pl = Ext.get('playList');
			if (pl)
				pl.setHeight(colHeight - pl.getTop() + right.getTop());
				
			Playlist.highlightCurrent();
		},
		
		highlightCurrent : function(id){
			el = Ext.get('playList');
			plPos = el.getScroll();
			plView = el.getViewSize();
			
			if (el = Ext.get(id || 'playlistCurrentSong')) {
				if (el.getTop() > plPos.top + plView.height
					|| el.getBottom() < plPos.top)
						el.scrollIntoView('playList');
			}

			menuItems = Ext.DomQuery.select('div.currentSong');
			for(var i = 0; i < menuItems.length; i++) {
				el = Ext.get(menuItems[i].id);
				if (el)
					el.replaceClass('currentSong', 'selectorMarker')
			};
			
			el = Ext.get((id || 'playlistCurrentSong') + 'Selector');
				if (el)
					el.replaceClass('selectorMarker', 'currentSong')
		}
	}
}();

Player = function(){
	var pollTimer;
	var playTimeTimer;
	var playTime = 0;
	var volumeClicked = 0;

	var playerStatus = {
		power: null,
		modus: null,
		title: null,
		track: null,
		volume: null
	};

	return {
		init : function(){
			Ext.Ajax.method = 'POST';
			Ext.Ajax.url = '/jsonrpc.js'; 
			Ext.Ajax.timeout = 4000;

			volumeUp = new Ext.util.ClickRepeater('ctrlVolumeUp', {
				accelerate: true
			});

			// volume buttons can be held
			volumeUp.on({
				'click': {
					fn: function(){
						volumeClicked++;
						if (volumeClicked > 4) {
							this.setVolume(volumeClicked, '+');
							volumeClicked = 0;
						}
					},
					scope: this
				},
				'mouseup': {
					fn: function(){
						this.setVolume(volumeClicked, '+');
						volumeClicked = 0;
					},
					scope: this
				}
			});

			volumeDown = new Ext.util.ClickRepeater('ctrlVolumeDown', {
				accelerate: true
			});
			
			volumeDown.on({
				'click': {
					fn: function(){
						volumeClicked++;
						if (volumeClicked > 4) {
							this.setVolume(volumeClicked, '-');
							volumeClicked = 0;
						}
					},
					scope: this
				},
				'mouseup': {
					fn: function(){
						this.setVolume(volumeClicked, '-');
						volumeClicked = 0;
					},
					scope: this
				}
			});


// TODO: set volume when clicking on volume bar - broken in FF&Safari, getting negative values :-(
/*			Ext.get('ctrlVolume').on('click', function(ev, target){
				if (el = Ext.get(target)) {
					x = el.getX();
					x = Ext.fly(target).getX();
					x = 100 * (ev.getPageX() - el.getX()) / el.getWidth();
					alert(x);
				}
			});
*/
			pollTimer = new Ext.util.DelayedTask(this.getStatus, this);
			playTimeTimer = new Ext.util.DelayedTask(this.updatePlayTime, this);
			this.getStatus();
		},

		updatePlayTime : function(time, totalTime){
			if (playerStatus.mode == 'play') {
				if (! isNaN(time))
					playTime = time;
	
				if (! isNaN(totalTime))
					Ext.get('ctrlTotalTime').update(' (' + this.formatTime(totalTime) + ')');
					
				Ext.get('ctrlPlaytime').update(this.formatTime(playTime));
				playTime += 0.5;
			}
			else
				Ext.get('ctrlPlaytime').update(this.formatTime(0));
			
			playTimeTimer.delay(500);
		},

		formatTime : function(seconds){
			hours = Math.floor(seconds / 3600);
			minutes = Math.floor((seconds - hours*3600) / 60);
			seconds = Math.floor(seconds % 60);

			formattedTime = (hours ? hours + ':' : '');
			formattedTime += (minutes ? (minutes < 10 && hours ? '0' : '') + minutes : '0') + ':';
			formattedTime += (seconds ? (seconds < 10 ? '0' : '') + seconds : '00');
			return formattedTime;
		},

		updateStatus : function(response) {

			if (response && response.responseText) {
				var responseText = Ext.util.JSON.decode(response.responseText);
				
				// only continue if we got a result and player
				if (responseText.result && responseText.result.player_connected) {
					var result = responseText.result;
					if (result.power && result.playlist_tracks > 0) {
						// update the playlist if it's available
						if (Ext.get('playList') && result.playlist_cur_index) {
							Playlist.highlightCurrent('playlistSong' + result.playlist_cur_index);
						}

						Ext.get('ctrlCurrentTitle').update(
							result.current_title ? result.current_title : (
								(result.playlist_loop[0].disc ? result.playlist_loop[0].disc + '-' : '')
								+ result.playlist_loop[0].tracknum + ". " + result.playlist_loop[0].title
							)
						);
//						Ext.get('statusSongCount').update(result.playlist_tracks);
//						Ext.get('statusPlayNum').update(result.playlist_cur_index + 1);
						Ext.get('ctrlBitrate').update(result.playlist_loop[0].bitrate);
						Ext.get('ctrlCurrentArtist').update(result.playlist_loop[0].artist);
						Ext.get('ctrlCurrentAlbum').update(
							result.playlist_loop[0].album 
							+ (result.playlist_loop[0].year ? ' (' + result.playlist_loop[0].year +')' : '')
						);

						this.updatePlayTime(result.time ? result.time : 0, result.duration ? result.duration : 0);

						if (result.playlist_loop[0].id) {
							Ext.get('ctrlCurrentArt').update('<img src="/music/' + result.playlist_loop[0].id + '/cover_96x96.jpg">');
						}

						// update play/pause button
						Ext.get('ctrlMode').update('<img src="' + webroot + 'html/images/' + (result.mode=='play' ? 'btn_pause_normal.png' : 'btn_play_normal.png') + '">');

						// update volume button
						volumeIcon = 'level_5';
						if (result['mixer volume'] <= 0)
							volumeIcon = 'level_0';
						else if (result['mixer volume'] >= 100)
							volumeIcon = 'level_11';
						else {
							volVal = Math.ceil(result['mixer volume']/9.9);
							volumeIcon = 'level_' + volVal;
						}
						Ext.get('ctrlVolume').update('<img src="' + webroot + 'html/images/' + volumeIcon + '.png">');

						playerStatus = {
							power: result.power,
							mode: result.mode,
							title: result.current_title,
							track: result.playlist_loop[0].url,
							volume: result['mixer volume']
						};
					}
				}
			}
			pollTimer.delay(5000);
		},

		getUpdate : function(response){
			Ext.Ajax.request({
				failure: this.updateStatus,
				success: this.updateStatus,

				params: Ext.util.JSON.encode({
					id: 1, 
					method: "slim.request", 
					params: [ 
						playerid,
						[ 
							"status",
							"-",
							1,
							"tags:gabehldiqtyru"
						]
					]
				}),
				scope: this
			});
		},
		
		
		// only poll to see whether the currently playing song has changed
		// don't request all status info to minimize performance impact on the server
		getStatus : function() {
			Ext.Ajax.request({
				params: Ext.util.JSON.encode({
					id: 1, 
					method: "slim.request", 
					params: [ 
						playerid,
						[ 
							"status",
							"-",
							1,
							"tags:u"
						]
					]
				}),

				success: function(response){
					if (response && response.responseText) {
						var responseText = Ext.util.JSON.decode(response.responseText);
						
						// only continue if we got a result and player
						if (responseText.result && responseText.result.player_connected) {
							var result = responseText.result;
							if ((result.power && result.power != playerStatus.power) ||
								(result.mode && result.mode != playerStatus.mode) ||
								(result.current_title && result.current_title != playerStatus.title) ||
								(result.playlist_tracks > 0 && result.playlist_loop[0].url != playerStatus.track))
							{
								this.getUpdate();
							}

							else if (result['mixer volume'] && result['mixer volume'] != playerStatus.volume) {
								this.updateStatus(response)
							}
							else
								this.updatePlayTime(result.time, result.duration);
						}
					}
				},

				scope: this
			});
			
			pollTimer.delay(5000);
		},

		playerControl : function(action){
			Ext.Ajax.request({
				params: Ext.util.JSON.encode({
					id: 1, 
					method: "slim.request", 
					params: [ 
						playerid,
						action
					]
				}),
				success: this.getUpdate,
				scope: this
			});
		},

		ctrlNext : function(){ this.playerControl(['playlist', 'index', '+1']) },
		ctrlPrevious : function(){ this.playerControl(['playlist', 'index', '-1']) },
		ctrlTogglePlay : function(){
			if (playerStatus.power == '0' || playerStatus.mode == 'stop')
				this.playerControl(['play']);
			else
				this.playerControl(['pause']);
		},

		openPlayerControl : function(){
			window.open(webroot + 'status_header.html', "gaasd", "width=500,height=165");
		},

		// values could be adjusted if not enough
		volumeUp : function(){ this.setVolume(1, '+') },
		volumeDown : function(){ this.setVolume(1, '-') },
		setVolume : function(amount, d){
			amount *= 2.5;
			if (d)
				amount = d + amount;
			this.playerControl(['mixer', 'volume', amount]);
		}
	}
}();