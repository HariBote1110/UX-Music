export namespace main {
	
	export class Song {
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
	
	    static createFrom(source: any = {}) {
	        return new Song(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
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

