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
	
	    static createFrom(source: any = {}) {
	        return new Request(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.songPath = source["songPath"];
	        this.lines = source["lines"];
	        this.language = source["language"];
	        this.profile = source["profile"];
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

