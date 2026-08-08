export namespace audio {
	
	export class Device {
	    id: string;
	    name: string;
	    isDefault: boolean;
	    maxChannels: number;
	
	    static createFrom(source: any = {}) {
	        return new Device(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.isDefault = source["isDefault"];
	        this.maxChannels = source["maxChannels"];
	    }
	}

}

export namespace cdrip {
	
	export class Track {
	    number: number;
	    title: string;
	    artist: string;
	    album: string;
	    sectors: number;
	    length?: string;
	
	    static createFrom(source: any = {}) {
	        return new Track(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.number = source["number"];
	        this.title = source["title"];
	        this.artist = source["artist"];
	        this.album = source["album"];
	        this.sectors = source["sectors"];
	        this.length = source["length"];
	    }
	}
	export class ReleaseInfo {
	    id: string;
	    title: string;
	    artist: string;
	    tracks: Track[];
	    artwork?: string;
	
	    static createFrom(source: any = {}) {
	        return new ReleaseInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.title = source["title"];
	        this.artist = source["artist"];
	        this.tracks = this.convertValues(source["tracks"], Track);
	        this.artwork = source["artwork"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace lyricssync {
	
	export class AlignedLine {
	    index: number;
	    text: string;
	    timestamp: number;
	    confidence: number;
	    source: string;
	
	    static createFrom(source: any = {}) {
	        return new AlignedLine(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.index = source["index"];
	        this.text = source["text"];
	        this.timestamp = source["timestamp"];
	        this.confidence = source["confidence"];
	        this.source = source["source"];
	    }
	}
	export class DetectedSegment {
	    start: number;
	    end: number;
	    text: string;
	
	    static createFrom(source: any = {}) {
	        return new DetectedSegment(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.start = source["start"];
	        this.end = source["end"];
	        this.text = source["text"];
	    }
	}
	export class Request {
	    songPath: string;
	    lines: string[];
	    language: string;
	    profile: string;
	    allowModelDownload?: boolean;
	    whisperModel?: string;
	
	    static createFrom(source: any = {}) {
	        return new Request(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.songPath = source["songPath"];
	        this.lines = source["lines"];
	        this.language = source["language"];
	        this.profile = source["profile"];
	        this.allowModelDownload = source["allowModelDownload"];
	        this.whisperModel = source["whisperModel"];
	    }
	}
	export class Result {
	    success: boolean;
	    lines?: AlignedLine[];
	    matchedCount?: number;
	    detectedBy?: string;
	    detectedSegments?: DetectedSegment[];
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new Result(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.success = source["success"];
	        this.lines = this.convertValues(source["lines"], AlignedLine);
	        this.matchedCount = source["matchedCount"];
	        this.detectedBy = source["detectedBy"];
	        this.detectedSegments = this.convertValues(source["detectedSegments"], DetectedSegment);
	        this.error = source["error"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace moodspecial {
	
	export class Feature {
	    title: string;
	    description: string;
	    orderedTrackIds: string[];
	    perTrackComments: Record<string, string>;
	
	    static createFrom(source: any = {}) {
	        return new Feature(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.title = source["title"];
	        this.description = source["description"];
	        this.orderedTrackIds = source["orderedTrackIds"];
	        this.perTrackComments = source["perTrackComments"];
	    }
	}

}

export namespace mtp {
	
	export class DeleteOptions {
	    storageId: number;
	    files: string[];
	
	    static createFrom(source: any = {}) {
	        return new DeleteOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.storageId = source["storageId"];
	        this.files = source["files"];
	    }
	}
	export class MakeDirOptions {
	    storageId: number;
	    fullPath: string;
	
	    static createFrom(source: any = {}) {
	        return new MakeDirOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.storageId = source["storageId"];
	        this.fullPath = source["fullPath"];
	    }
	}
	export class Storage {
	    Sid: number;
	    // Go type: struct { StorageDescription string "json:\"StorageDescription\""; MaxCapability int64 "json:\"MaxCapability\""; FreeSpaceInBytes int64 "json:\"FreeSpaceInBytes\"" }
	    Info: any;
	
	    static createFrom(source: any = {}) {
	        return new Storage(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Sid = source["Sid"];
	        this.Info = this.convertValues(source["Info"], Object);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class TransferOptions {
	    storageId: number;
	    sources: string[];
	    destination: string;
	    preprocessFiles: boolean;
	
	    static createFrom(source: any = {}) {
	        return new TransferOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.storageId = source["storageId"];
	        this.sources = source["sources"];
	        this.destination = source["destination"];
	        this.preprocessFiles = source["preprocessFiles"];
	    }
	}
	export class WalkOptions {
	    storageId: number;
	    fullPath: string;
	    recursive: boolean;
	    skipDisallowedFiles: boolean;
	    skipHiddenFiles: boolean;
	
	    static createFrom(source: any = {}) {
	        return new WalkOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.storageId = source["storageId"];
	        this.fullPath = source["fullPath"];
	        this.recursive = source["recursive"];
	        this.skipDisallowedFiles = source["skipDisallowedFiles"];
	        this.skipHiddenFiles = source["skipHiddenFiles"];
	    }
	}

}

export namespace normalize {
	
	export class AnalysisResult {
	    success: boolean;
	    loudness: number;
	    truePeak: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new AnalysisResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.success = source["success"];
	        this.loudness = source["loudness"];
	        this.truePeak = source["truePeak"];
	        this.error = source["error"];
	    }
	}
	export class OutputSettings {
	    mode: string;
	    path: string;
	
	    static createFrom(source: any = {}) {
	        return new OutputSettings(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.mode = source["mode"];
	        this.path = source["path"];
	    }
	}
	export class NormalizeJob {
	    id: string;
	    filePath: string;
	    gain: number;
	    backup: boolean;
	    output: OutputSettings;
	    basePath: string;
	
	    static createFrom(source: any = {}) {
	        return new NormalizeJob(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.filePath = source["filePath"];
	        this.gain = source["gain"];
	        this.backup = source["backup"];
	        this.output = this.convertValues(source["output"], OutputSettings);
	        this.basePath = source["basePath"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class NormalizeResult {
	    success: boolean;
	    outputPath: string;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new NormalizeResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.success = source["success"];
	        this.outputPath = source["outputPath"];
	        this.error = source["error"];
	    }
	}

}

export namespace scanner {
	
	export class Song {
	    id: string;
	    path: string;
	    title: string;
	    artist: string;
	    album: string;
	    albumartist: string;
	    year: number;
	    genre: string;
	    duration: number;
	    trackNumber: number;
	    discNumber: number;
	    fileSize: number;
	    fileType: string;
	    sampleRate?: number;
	    bitDepth?: number;
	    artwork?: any;
	
	    static createFrom(source: any = {}) {
	        return new Song(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.path = source["path"];
	        this.title = source["title"];
	        this.artist = source["artist"];
	        this.album = source["album"];
	        this.albumartist = source["albumartist"];
	        this.year = source["year"];
	        this.genre = source["genre"];
	        this.duration = source["duration"];
	        this.trackNumber = source["trackNumber"];
	        this.discNumber = source["discNumber"];
	        this.fileSize = source["fileSize"];
	        this.fileType = source["fileType"];
	        this.sampleRate = source["sampleRate"];
	        this.bitDepth = source["bitDepth"];
	        this.artwork = source["artwork"];
	    }
	}
	export class ScanResult {
	    songs: Song[];
	    count: number;
	    timeMs: number;
	
	    static createFrom(source: any = {}) {
	        return new ScanResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.songs = this.convertValues(source["songs"], Song);
	        this.count = source["count"];
	        this.timeMs = source["timeMs"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace server {
	
	export class AudioEmbedAnalyseResponse {
	    considered: number;
	    skipped: number;
	    analysed: number;
	    failed: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new AudioEmbedAnalyseResponse(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.considered = source["considered"];
	        this.skipped = source["skipped"];
	        this.analysed = source["analysed"];
	        this.failed = source["failed"];
	        this.error = source["error"];
	    }
	}
	export class AudioEmbedSearchHit {
	    trackId: string;
	    path: string;
	    score: number;
	
	    static createFrom(source: any = {}) {
	        return new AudioEmbedSearchHit(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.trackId = source["trackId"];
	        this.path = source["path"];
	        this.score = source["score"];
	    }
	}
	export class AudioEmbedStatus {
	    stored: number;
	    version: string;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new AudioEmbedStatus(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.stored = source["stored"];
	        this.version = source["version"];
	        this.error = source["error"];
	    }
	}
	export class AudioEqualizerSettings {
	    active: boolean;
	    preamp: number;
	    bands: number[];
	
	    static createFrom(source: any = {}) {
	        return new AudioEqualizerSettings(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.active = source["active"];
	        this.preamp = source["preamp"];
	        this.bands = source["bands"];
	    }
	}
	export class PerformanceSnapshot {
	    timestampUtc: string;
	    processRssMb: number;
	    processCpuPercent: number;
	    goHeapAllocMb: number;
	    goSysMb: number;
	    goNumGoroutine: number;
	    librarySongCount: number;
	    performanceSourceOk: boolean;
	
	    static createFrom(source: any = {}) {
	        return new PerformanceSnapshot(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.timestampUtc = source["timestampUtc"];
	        this.processRssMb = source["processRssMb"];
	        this.processCpuPercent = source["processCpuPercent"];
	        this.goHeapAllocMb = source["goHeapAllocMb"];
	        this.goSysMb = source["goSysMb"];
	        this.goNumGoroutine = source["goNumGoroutine"];
	        this.librarySongCount = source["librarySongCount"];
	        this.performanceSourceOk = source["performanceSourceOk"];
	    }
	}
	export class SyncAutoResult {
	    checkedDevices: number;
	    syncedDevices: number;
	    failedDevices: number;
	    pushedPlayEvents: number;
	    syncedArtwork: number;
	    pulledTracks: number;
	    skippedTracks: number;
	    paused: boolean;
	    pauseReason?: string;
	    freeSpaceBytes?: number;
	    minFreeSpaceBytes?: number;
	    errors?: string[];
	
	    static createFrom(source: any = {}) {
	        return new SyncAutoResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.checkedDevices = source["checkedDevices"];
	        this.syncedDevices = source["syncedDevices"];
	        this.failedDevices = source["failedDevices"];
	        this.pushedPlayEvents = source["pushedPlayEvents"];
	        this.syncedArtwork = source["syncedArtwork"];
	        this.pulledTracks = source["pulledTracks"];
	        this.skippedTracks = source["skippedTracks"];
	        this.paused = source["paused"];
	        this.pauseReason = source["pauseReason"];
	        this.freeSpaceBytes = source["freeSpaceBytes"];
	        this.minFreeSpaceBytes = source["minFreeSpaceBytes"];
	        this.errors = source["errors"];
	    }
	}
	export class SyncDeviceRecord {
	    deviceId: string;
	    displayName: string;
	    baseUrl?: string;
	    roles?: string[];
	    paired: boolean;
	    lastSeenAt?: string;
	
	    static createFrom(source: any = {}) {
	        return new SyncDeviceRecord(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.deviceId = source["deviceId"];
	        this.displayName = source["displayName"];
	        this.baseUrl = source["baseUrl"];
	        this.roles = source["roles"];
	        this.paired = source["paired"];
	        this.lastSeenAt = source["lastSeenAt"];
	    }
	}
	export class SyncPairingConfirmResult {
	    remoteDeviceId: string;
	    remoteDisplayName: string;
	    tokenSaved: boolean;
	
	    static createFrom(source: any = {}) {
	        return new SyncPairingConfirmResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.remoteDeviceId = source["remoteDeviceId"];
	        this.remoteDisplayName = source["remoteDisplayName"];
	        this.tokenSaved = source["tokenSaved"];
	    }
	}
	export class SyncPairingStartResult {
	    baseUrl: string;
	    sessionId: string;
	    localDeviceId: string;
	    remoteDeviceId: string;
	    remoteDisplayName: string;
	    code: string;
	    expiresAt: string;
	
	    static createFrom(source: any = {}) {
	        return new SyncPairingStartResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.baseUrl = source["baseUrl"];
	        this.sessionId = source["sessionId"];
	        this.localDeviceId = source["localDeviceId"];
	        this.remoteDeviceId = source["remoteDeviceId"];
	        this.remoteDisplayName = source["remoteDisplayName"];
	        this.code = source["code"];
	        this.expiresAt = source["expiresAt"];
	    }
	}
	export class SyncPullResult {
	    remoteDeviceId: string;
	    remoteDisplayName: string;
	    downloaded: number;
	    skipped: number;
	    failed: number;
	    importedPaths: string[];
	    errors?: string[];
	
	    static createFrom(source: any = {}) {
	        return new SyncPullResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.remoteDeviceId = source["remoteDeviceId"];
	        this.remoteDisplayName = source["remoteDisplayName"];
	        this.downloaded = source["downloaded"];
	        this.skipped = source["skipped"];
	        this.failed = source["failed"];
	        this.importedPaths = source["importedPaths"];
	        this.errors = source["errors"];
	    }
	}
	export class SyncPushResult {
	    remoteDeviceId: string;
	    remoteDisplayName: string;
	    transferred: number;
	    skipped: number;
	    failed: number;
	    encodingMode: string;
	    importedPaths: string[];
	    errors?: string[];
	
	    static createFrom(source: any = {}) {
	        return new SyncPushResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.remoteDeviceId = source["remoteDeviceId"];
	        this.remoteDisplayName = source["remoteDisplayName"];
	        this.transferred = source["transferred"];
	        this.skipped = source["skipped"];
	        this.failed = source["failed"];
	        this.encodingMode = source["encodingMode"];
	        this.importedPaths = source["importedPaths"];
	        this.errors = source["errors"];
	    }
	}
	export class SyncTrackRef {
	    sourceDeviceId: string;
	    sourceTrackId: string;
	
	    static createFrom(source: any = {}) {
	        return new SyncTrackRef(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.sourceDeviceId = source["sourceDeviceId"];
	        this.sourceTrackId = source["sourceTrackId"];
	    }
	}
	export class SyncTransferOptions {
	    encodingMode: string;
	
	    static createFrom(source: any = {}) {
	        return new SyncTransferOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.encodingMode = source["encodingMode"];
	    }
	}
	export class YouTubeEmbedLoudness {
	    available: boolean;
	    effectiveLoudnessLufs: number;
	
	    static createFrom(source: any = {}) {
	        return new YouTubeEmbedLoudness(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.available = source["available"];
	        this.effectiveLoudnessLufs = source["effectiveLoudnessLufs"];
	    }
	}

}

export namespace uxsync {
	
	export class MDNSPeer {
	    deviceId: string;
	    displayName: string;
	    host: string;
	    hosts: string[];
	    port: number;
	    hostName: string;
	    protocolVersion: string;
	    schemaVersion?: string;
	    capabilities?: string[];
	    roles: string[];
	    reachableBaseUrl?: string;
	
	    static createFrom(source: any = {}) {
	        return new MDNSPeer(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.deviceId = source["deviceId"];
	        this.displayName = source["displayName"];
	        this.host = source["host"];
	        this.hosts = source["hosts"];
	        this.port = source["port"];
	        this.hostName = source["hostName"];
	        this.protocolVersion = source["protocolVersion"];
	        this.schemaVersion = source["schemaVersion"];
	        this.capabilities = source["capabilities"];
	        this.roles = source["roles"];
	        this.reachableBaseUrl = source["reachableBaseUrl"];
	    }
	}

}

