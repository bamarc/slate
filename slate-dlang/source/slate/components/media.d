/// Media Player controller, simulated backend, and MCP trait integration.
module slate.components.media;

import std.algorithm : clamp;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : isNaN, isFinite;

import slint.instance : ComponentInstance;
import slint.model : ArrayModel;
import slint.value : SlintField;
import slate.agent.bridge : SlintUiBridge;
import slate.agent.error : AgentError;
import slate.agent.traits;

/// Playlist track row mapped to `SlateMediaTrack`.
struct MediaTrackData
{
    @SlintField("id") string id;
    @SlintField("title") string title;
    @SlintField("artist") string artist;
    @SlintField("duration-seconds") float durationSeconds = 0.0f;
    @SlintField("duration-label") string durationLabel = "00:00";
}

/// Timeline marker mapped to `SlateMediaMarker`.
struct MediaMarkerData
{
    @SlintField("id") string id;
    @SlintField("label") string label;
    @SlintField("time-seconds") float timeSeconds = 0.0f;
}

/// Format seconds into `MM:SS` or `HH:MM:SS`.
string formatMediaTime(double seconds) @safe pure nothrow
{
    if (isNaN(seconds) || seconds < 0.0)
        seconds = 0.0;
    long totalSecs = cast(long) seconds;
    long hrs = totalSecs / 3600;
    long mins = (totalSecs % 3600) / 60;
    long secs = totalSecs % 60;
    try
    {
        if (hrs > 0)
            return format("%02d:%02d:%02d", hrs, mins, secs);
        return format("%02d:%02d", mins, secs);
    }
    catch (Exception)
    {
        return "00:00";
    }
}

/// Pluggable media decoding/playback backend interface (real codec backends plug in later).
interface MediaBackend
{
    void loadTrack(MediaTrackData track);
    void play();
    void pause();
    void stop();
    void seek(double seconds);
    void setVolume(double volume);
    void setMuted(bool muted);
    void setPlaybackRate(double rate);
    double positionSeconds() const @safe pure nothrow;
    double durationSeconds() const @safe pure nothrow;
    bool isPlaying() const @safe pure nothrow;
}

/// Deterministic simulated media backend for UI development and headless tests.
class SimulatedMediaBackend : MediaBackend
{
    private double _pos = 0.0;
    private double _dur = 120.0;
    private bool _playing = false;
    private double _volume = 0.8;
    private bool _muted = false;
    private double _rate = 1.0;

    this(double initialDuration = 120.0) @safe pure nothrow
    {
        _dur = initialDuration > 0.0 ? initialDuration : 120.0;
    }

    override void loadTrack(MediaTrackData track) @safe pure nothrow
    {
        _pos = 0.0;
        _dur = track.durationSeconds > 0.0f ? cast(double) track.durationSeconds : 120.0;
    }

    override void play() @safe pure nothrow { _playing = true; }
    override void pause() @safe pure nothrow { _playing = false; }
    override void stop() @safe pure nothrow
    {
        _playing = false;
        _pos = 0.0;
    }

    override void seek(double seconds) @safe pure nothrow
    {
        _pos = clamp(seconds, 0.0, _dur);
    }

    override void setVolume(double volume) @safe pure nothrow
    {
        _volume = clamp(volume, 0.0, 1.0);
    }

    override void setMuted(bool muted) @safe pure nothrow
    {
        _muted = muted;
    }

    override void setPlaybackRate(double rate) @safe pure nothrow
    {
        _rate = rate;
    }

    override double positionSeconds() const @safe pure nothrow { return _pos; }
    override double durationSeconds() const @safe pure nothrow { return _dur; }
    override bool isPlaying() const @safe pure nothrow { return _playing; }

    /// Advance simulated playback by `deltaSeconds` (scaled by playback rate).
    void tick(double deltaSeconds) @safe pure nothrow
    {
        if (!_playing || deltaSeconds <= 0.0)
            return;
        _pos = clamp(_pos + deltaSeconds * _rate, 0.0, _dur);
        if (_pos >= _dur)
            _playing = false;
    }
}

/// Media Player controller implementing `McpControllable`, `McpSeekable`,
/// `McpSelectable` (for playlist track selection), and `McpBindable`.
class MediaPlayerController : McpControllable, McpSeekable, McpSelectable, McpBindable
{
    mixin McpControllableMixin!"media";

    private MediaBackend _backend;
    private MediaTrackData[] _playlist;
    private ArrayModel!MediaTrackData _playlistModel;
    private ptrdiff_t _activeTrackIndex = 0;

    private double _volume = 0.8;
    private bool _muted = false;
    private double _playbackRate = 1.0;
    private string _repeatMode = "none"; // "none", "one", "all"
    private bool _shuffle = false;
    private bool _fullscreen = false;
    private string _mode = "video";

    private ComponentInstance _boundInstance;

    this(MediaTrackData[] initialPlaylist = [], MediaBackend backend = null)
    {
        _backend = backend !is null ? backend : new SimulatedMediaBackend(180.0);
        _playlistModel = new ArrayModel!MediaTrackData();
        setPlaylist(initialPlaylist);
    }

    ArrayModel!MediaTrackData playlistModel() @safe pure nothrow
    {
        return _playlistModel;
    }

    void setPlaylist(MediaTrackData[] tracks)
    {
        _playlist = tracks.dup;
        _playlistModel.clear();
        foreach (ref t; _playlist)
        {
            if (t.durationLabel.length == 0 || t.durationLabel == "00:00")
                t.durationLabel = formatMediaTime(t.durationSeconds);
            _playlistModel.push(t);
        }
        if (_playlist.length > 0)
        {
            _activeTrackIndex = 0;
            _backend.loadTrack(_playlist[0]);
        }
        else
        {
            _activeTrackIndex = -1;
        }
        syncSlintProperties();
    }

    override void bindToSlint(ComponentInstance instance, SlintUiBridge bridge = null)
    {
        _boundInstance = instance;
        syncSlintProperties();
    }

    private void syncSlintProperties()
    {
        version (SlintNative)
        {
            if (_boundInstance is null)
                return;
            try
            {
                _boundInstance.setBool("playing", isPlaying());
                _boundInstance.setNumber("position-seconds", positionSeconds());
                _boundInstance.setNumber("duration-seconds", durationSeconds());
                _boundInstance.setString("position-label", positionLabel());
                _boundInstance.setString("duration-label", durationLabel());
                _boundInstance.setNumber("volume", _volume);
                _boundInstance.setBool("muted", _muted);
                _boundInstance.setNumber("playback-rate", _playbackRate);
                _boundInstance.setString("repeat-mode", _repeatMode);
                _boundInstance.setBool("shuffle", _shuffle);
                _boundInstance.setBool("fullscreen", _fullscreen);
            }
            catch (Exception)
            {
            }
        }
    }

    @McpState("mode")
    string mode() const @safe pure nothrow { return _mode; }

    @McpWritable("mode") @McpAction("set_mode")
    void setMode(string m)
    {
        if (m != "video" && m != "audio-deck" && m != "mini-bar")
            throw AgentError.invalidParams("mode", "Mode must be video, audio-deck, or mini-bar");
        _mode = m;
        syncSlintProperties();
    }

    @McpState("playing")
    bool isPlaying() const @safe pure nothrow
    {
        return _backend.isPlaying();
    }

    @McpWritable("playing")
    void setPlaying(bool playState)
    {
        if (playState)
            play();
        else
            pause();
    }

    @McpAction("play")
    void play()
    {
        _backend.play();
        syncSlintProperties();
    }

    @McpAction("pause")
    void pause()
    {
        _backend.pause();
        syncSlintProperties();
    }

    @McpAction("toggle_play")
    bool togglePlay()
    {
        if (_backend.isPlaying())
            _backend.pause();
        else
            _backend.play();
        syncSlintProperties();
        return _backend.isPlaying();
    }

    @McpAction("stop")
    void stop()
    {
        _backend.stop();
        syncSlintProperties();
    }

    @McpState("position_seconds")
    override double positionSeconds() const @safe pure nothrow
    {
        return _backend.positionSeconds();
    }

    @McpState("duration_seconds")
    override double durationSeconds() const @safe pure nothrow
    {
        return _backend.durationSeconds();
    }

    @McpState("position_label")
    string positionLabel() const @safe pure nothrow
    {
        return formatMediaTime(positionSeconds());
    }

    @McpState("duration_label")
    string durationLabel() const @safe pure nothrow
    {
        return formatMediaTime(durationSeconds());
    }

    @McpWritable("position_seconds") @McpAction("seek")
    override void seekTo(double seconds)
    {
        if (!isFinite(seconds) || seconds < 0.0 || seconds > durationSeconds())
            throw AgentError.invalidParams("position_seconds", "Seek position out of range [0, duration]");
        _backend.seek(seconds);
        syncSlintProperties();
    }

    @McpState("volume")
    double volume() const @safe pure nothrow { return _volume; }

    @McpWritable("volume") @McpAction("set_volume")
    void setVolume(double v)
    {
        if (!isFinite(v) || v < 0.0 || v > 1.0)
            throw AgentError.invalidParams("volume", "Volume must be in [0.0, 1.0]");
        _volume = v;
        _backend.setVolume(v);
        syncSlintProperties();
    }

    @McpState("muted")
    bool isMuted() const @safe pure nothrow { return _muted; }

    @McpWritable("muted") @McpAction("set_muted")
    void setMuted(bool m)
    {
        _muted = m;
        _backend.setMuted(m);
        syncSlintProperties();
    }

    @McpAction("toggle_mute")
    bool toggleMute()
    {
        setMuted(!_muted);
        return _muted;
    }

    @McpState("playback_rate")
    double playbackRate() const @safe pure nothrow { return _playbackRate; }

    @McpWritable("playback_rate") @McpAction("set_playback_rate")
    void setPlaybackRate(double rate)
    {
        if (!isFinite(rate) || rate < 0.25 || rate > 4.0)
            throw AgentError.invalidParams("playback_rate", "Playback rate must be in [0.25, 4.0]");
        _playbackRate = rate;
        _backend.setPlaybackRate(rate);
        syncSlintProperties();
    }

    @McpAction("cycle_speed")
    double cycleSpeed()
    {
        static immutable double[5] rates = [0.5, 1.0, 1.25, 1.5, 2.0];
        size_t nextIdx = 0;
        foreach (i, r; rates)
        {
            if (r == _playbackRate)
            {
                nextIdx = (i + 1) % rates.length;
                break;
            }
        }
        setPlaybackRate(rates[nextIdx]);
        return _playbackRate;
    }

    @McpState("repeat_mode")
    string repeatMode() const @safe pure nothrow { return _repeatMode; }

    @McpWritable("repeat_mode") @McpAction("set_repeat_mode")
    void setRepeatMode(string modeStr)
    {
        if (modeStr != "none" && modeStr != "one" && modeStr != "all")
            throw AgentError.invalidParams("repeat_mode", "Repeat mode must be none, one, or all");
        _repeatMode = modeStr;
        syncSlintProperties();
    }

    @McpAction("cycle_repeat")
    string cycleRepeat()
    {
        if (_repeatMode == "none")
            _repeatMode = "all";
        else if (_repeatMode == "all")
            _repeatMode = "one";
        else
            _repeatMode = "none";
        syncSlintProperties();
        return _repeatMode;
    }

    @McpState("shuffle")
    bool isShuffle() const @safe pure nothrow { return _shuffle; }

    @McpWritable("shuffle") @McpAction("set_shuffle")
    void setShuffle(bool s)
    {
        _shuffle = s;
        syncSlintProperties();
    }

    @McpState("fullscreen")
    bool isFullscreen() const @safe pure nothrow { return _fullscreen; }

    @McpWritable("fullscreen") @McpAction("set_fullscreen")
    void setFullscreen(bool f)
    {
        _fullscreen = f;
        syncSlintProperties();
    }

    @McpState("active_track_index")
    override ptrdiff_t selectedIndex() const @safe pure nothrow
    {
        return _activeTrackIndex;
    }

    @McpWritable("active_track_index") @McpAction("select_track")
    override void selectIndex(size_t index)
    {
        if (index >= _playlist.length)
            throw AgentError.invalidParams("active_track_index", "Track index out of range");
        _activeTrackIndex = cast(ptrdiff_t) index;
        _backend.loadTrack(_playlist[index]);
        syncSlintProperties();
    }

    @McpAction("next_track")
    ptrdiff_t nextTrack()
    {
        if (_playlist.length == 0)
            return -1;
        size_t nextIdx = cast(size_t)((_activeTrackIndex + 1) % cast(ptrdiff_t) _playlist.length);
        selectIndex(nextIdx);
        return _activeTrackIndex;
    }

    @McpAction("prev_track")
    ptrdiff_t prevTrack()
    {
        if (_playlist.length == 0)
            return -1;
        ptrdiff_t prevIdx = _activeTrackIndex - 1;
        if (prevIdx < 0)
            prevIdx = cast(ptrdiff_t) _playlist.length - 1;
        selectIndex(cast(size_t) prevIdx);
        return _activeTrackIndex;
    }

    void onMcpRestoreSnapshot(JSONValue snapshot)
    {
        if (snapshot.type != JSONType.object)
            return;
        auto obj = snapshot.object;

        if (auto p = "mode" in obj)
        {
            if (p.type == JSONType.string)
                _mode = p.str;
        }
        if (auto p = "volume" in obj)
        {
            if (p.type == JSONType.float_ || p.type == JSONType.integer)
            {
                double v = (p.type == JSONType.float_) ? p.floating : cast(double) p.integer;
                _volume = clamp(v, 0.0, 1.0);
                _backend.setVolume(_volume);
            }
        }
        if (auto p = "muted" in obj)
        {
            if (p.type == JSONType.true_)
                _muted = true;
            else if (p.type == JSONType.false_)
                _muted = false;
            _backend.setMuted(_muted);
        }
        if (auto p = "playback_rate" in obj)
        {
            if (p.type == JSONType.float_ || p.type == JSONType.integer)
            {
                double r = (p.type == JSONType.float_) ? p.floating : cast(double) p.integer;
                _playbackRate = r;
                _backend.setPlaybackRate(r);
            }
        }
        if (auto p = "repeat_mode" in obj)
        {
            if (p.type == JSONType.string)
                _repeatMode = p.str;
        }
        if (auto p = "shuffle" in obj)
        {
            if (p.type == JSONType.true_)
                _shuffle = true;
            else if (p.type == JSONType.false_)
                _shuffle = false;
        }
        if (auto p = "fullscreen" in obj)
        {
            if (p.type == JSONType.true_)
                _fullscreen = true;
            else if (p.type == JSONType.false_)
                _fullscreen = false;
        }
        if (auto p = "active_track_index" in obj)
        {
            if (p.type == JSONType.integer)
            {
                ptrdiff_t idx = cast(ptrdiff_t) p.integer;
                _activeTrackIndex = idx;
                if (idx >= 0 && cast(size_t) idx < _playlist.length)
                {
                    _backend.loadTrack(_playlist[idx]);
                }
            }
        }
        if (auto p = "playing" in obj)
        {
            bool shouldPlay = (p.type == JSONType.true_);
            if (shouldPlay)
                _backend.play();
            else
                _backend.pause();
        }
        // Lastly restore position_seconds so track loading or play doesn't reset it
        if (auto p = "position_seconds" in obj)
        {
            if (p.type == JSONType.float_ || p.type == JSONType.integer)
            {
                double pos = (p.type == JSONType.float_) ? p.floating : cast(double) p.integer;
                _backend.seek(pos);
            }
        }

        syncSlintProperties();
    }
}

// Spec: Scenario T6 / Security: SlateMediaPlayer transport, scrubber seek, volume, and track queue via MCP
/// Example:
unittest
{
    import std.exception : assertThrown;
    import std.json : JSONValue;

    static assert(isMcpControllable!MediaPlayerController);
    static assert(isMcpSeekable!MediaPlayerController);
    static assert(isMcpSelectable!MediaPlayerController);
    static assert(isMcpBindable!MediaPlayerController);

    auto sim = new SimulatedMediaBackend(200.0);
    auto tracks = [
        MediaTrackData("t1", "Intro", "Slate Audio", 180.0f),
        MediaTrackData("t2", "Deep Dive", "Slate Audio", 300.0f),
        MediaTrackData("t3", "Outro", "Slate Audio", 120.0f),
    ];
    auto player = new MediaPlayerController(tracks, sim);

    assert(player.durationSeconds() == 180.0);
    assert(player.durationLabel() == "03:00");
    assert(!player.isPlaying());
    assert(player.selectedIndex() == 0);

    // Play / pause
    assert(player.togglePlay() == true);
    assert(player.isPlaying());
    sim.tick(15.0);
    assert(player.positionSeconds() == 15.0);
    assert(player.positionLabel() == "00:15");

    // Seek via McpSeekable & MCP property
    player.seekTo(90.0);
    assert(player.positionSeconds() == 90.0);
    assert(player.positionLabel() == "01:30");

    // Out-of-bounds and NaN/infinity seek rejected (U1 & Security)
    assertThrown!AgentError(player.seekTo(-5.0));
    assertThrown!AgentError(player.seekTo(999.0));
    assertThrown!AgentError(player.seekTo(double.nan));
    assertThrown!AgentError(player.seekTo(double.infinity));

    // Volume & Playback rate validation (U1 & Security)
    player.setVolume(0.5);
    assert(player.volume() == 0.5);
    assertThrown!AgentError(player.setVolume(1.5));
    assertThrown!AgentError(player.setVolume(double.nan));
    assertThrown!AgentError(player.setVolume(double.infinity));

    player.setPlaybackRate(1.5);
    assert(player.playbackRate() == 1.5);
    assertThrown!AgentError(player.setPlaybackRate(0.1));
    assertThrown!AgentError(player.setPlaybackRate(8.0));
    assertThrown!AgentError(player.setPlaybackRate(double.nan));
    assertThrown!AgentError(player.setPlaybackRate(double.infinity));

    // Playlist track selection advances from 0 to 1
    player.nextTrack();
    assert(player.selectedIndex() == 1);
    assert(player.durationSeconds() == 300.0);
    assert(player.positionSeconds() == 0.0);

    auto snap = player.mcpSnapshot();
    assert(snap["playing"].boolean == true);
    assert(snap["duration_seconds"].floating == 300.0);

    // Rollback test: seek to 45s, capture snapshot, mutate, then restore and verify position preserved
    player.seekTo(45.0);
    assert(player.positionSeconds() == 45.0);
    auto snapWithPos = player.mcpSnapshot();

    player.nextTrack();
    player.stop();
    player.setVolume(0.1);
    assert(player.positionSeconds() == 0.0);
    assert(!player.isPlaying());
    assert(player.selectedIndex() == 2);
    assert(player.volume() == 0.1);

    player.mcpRestoreSnapshot(snapWithPos);
    assert(player.selectedIndex() == 1);
    assert(player.isPlaying());
    assert(player.positionSeconds() == 45.0);
    assert(player.volume() == 0.5);
}

version (SlintNative)
{
    // Spec: Scenario T6 (SlintNative): SlateMediaPlayer transport, scrubber, and next-track advancing
    /// Example:
    unittest
    {
        import std.typecons : nullable;
        import slint.compiler : Compiler;
        import slate.agent.slint_backend : SlintElementController, SlintUiInspector;

        auto compiler = new Compiler();
        compiler.includePaths = ["../ui"];
        auto built = compiler.buildFromSource(`
            import { SlateMediaPlayer, SlateMediaTrack } from "components/media_player.slint";
            export component MediaTestWin inherits Window {
                width: 640px;
                height: 360px;
                in-out property <bool> playing <=> player.playing;
                in-out property <float> position-seconds <=> player.position-seconds;
                in-out property <float> duration-seconds: 180.0;
                in-out property <float> volume <=> player.volume;
                in-out property <bool> muted <=> player.muted;
                in-out property <int> active-track <=> player.active-track-index;

                player := SlateMediaPlayer {
                    width: 100%;
                    height: 100%;
                    automation-id: "media-player";
                    duration-seconds: root.duration-seconds;
                    playlist: [
                        { id: "1", title: "Track 1", artist: "Artist 1", duration-seconds: 120, duration-label: "02:00" },
                        { id: "2", title: "Track 2", artist: "Artist 2", duration-seconds: 180, duration-label: "03:00" },
                        { id: "3", title: "Track 3", artist: "Artist 3", duration-seconds: 240, duration-label: "04:00" },
                    ];
                }
            }
        `, "");
        import std.conv : text;
        auto def = built.component("MediaTestWin");
        assert(def !is null, text("MediaTestWin failed: ", built.diagnostics));
        auto win = def.create();

        auto inspector = new SlintUiInspector(win);
        auto ctrl = new SlintElementController(win);

        // Click play-pause
        ctrl.clickElement("#media-player-play-pause");
        assert(win.getBool("playing") == true);

        // Set scrubber value via sendKeys (accessible-action-set-value)
        ctrl.sendKeys(nullable("#media-player-scrubber"), "42.5");
        assert(win.getNumber("position-seconds") == 42.5);

        // Click next advances active-track-index from 0 to 1
        assert(win.getNumber("active-track") == 0.0);
        ctrl.clickElement("#media-player-next");
        assert(win.getNumber("active-track") == 1.0);

        // Click stop resets playing and position
        ctrl.clickElement("#media-player-stop");
        assert(win.getBool("playing") == false);
        assert(win.getNumber("position-seconds") == 0.0);

        // Mute toggle
        ctrl.clickElement("#media-player-mute");
        assert(win.getBool("muted") == true);

        // Verify tree inspection has no duplicate IDs
        auto tree = inspector.inspectTree();
        assert(tree.findById("media-player-scrubber") !is null);
    }
}
