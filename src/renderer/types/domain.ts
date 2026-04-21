/**
 * Renderer domain types (narrower than generated Wails bindings).
 */

export interface Song {
  id?: string;
  title?: string;
  artist?: string;
  album?: string;
  albumArtist?: string;
  path?: string;
  duration?: number;
  year?: number;
  artwork?: ArtworkRef | string | null;
  [key: string]: unknown;
}

/** Context stored while waiting for loudness analysis to finish. */
export interface SongWaitingContext {
  index: number;
  sourceList: Song[];
  [key: string]: unknown;
}

export interface ArtworkRef {
  full?: string;
  thumb?: string;
  [key: string]: unknown;
}

export interface AlbumGroup {
  [albumKey: string]: Song[];
}

export interface LibraryLoadPayload {
  songs?: Song[];
  albums?: Record<string, unknown>;
}

export interface PlaylistDetails {
  songs?: Song[];
  name?: string;
  [key: string]: unknown;
}

export interface PlayCountEntry {
  count: number;
  [key: string]: unknown;
}

export type PlayCountsMap = Record<string, PlayCountEntry>;

export interface AppSettings {
  volume?: number;
  visualizerMode?: string;
  audioOutputId?: string | null;
  isShuffled?: boolean;
  groupAlbumArt?: boolean;
  enableYouTube?: boolean;
  libraryPath?: string;
  [key: string]: unknown;
}

export interface RenamePlaylistPayload {
  oldName?: string;
  newName?: string;
  [key: string]: unknown;
}

export interface AddSongsToPlaylistPayload {
  playlistName?: string;
  songIds?: string[];
  [key: string]: unknown;
}

export interface SongSkippedPayload {
  song?: Song;
  [key: string]: unknown;
}

export interface QuizConfig {
  length: number;
  difficulty: string;
}

export interface QuizQuestion {
  [key: string]: unknown;
}

export interface DetailViewState {
  type: string | null;
  identifier: string | null;
  data: unknown;
}

export type PlaybackMode = 'normal' | 'loop-all' | 'loop-one';
