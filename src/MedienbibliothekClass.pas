{

    Unit MedienbibliothekClass

    One of the Basic-Units - The Library

    ---------------------------------------------------------------
    Nemp - Noch ein Mp3-Player
    Copyright (C) 2005-2019, Daniel Gaussmann
    http://www.gausi.de
    mail@gausi.de
    ---------------------------------------------------------------
    This program is free software; you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by the
    Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
    or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
    for more details.

    You should have received a copy of the GNU General Public License along
    with this program; if not, write to the Free Software Foundation, Inc.,
    51 Franklin St, Fifth Floor, Boston, MA 02110, USA

    See license.txt for more information

    ---------------------------------------------------------------
}

(*
Hinweise f�r eventuelle Erweiterungen:
--------------------------------------
- Die Threads werden mit der VCL per SendMessage synchronisiert.
  D.h.: Eine VCL-Aktion, die was l�nger dauert und deswegen Application.ProcessMessages
        verwendet, DARF NICHT gestartet werden, wenn der MedienBibStatus <> 0 ist!
        Denn das bedeutet, dass ein Update-Vorgang gestartet wurde, und evtl. bald eine
        Message kommt, die der VCL mitteilt, dass exklusiver Zugriff erforderlich ist.
        Zus�tzlich muss eine solche VCL-Aktion den MedienBibStatus auf 3 setzen.

*)

unit MedienbibliothekClass;

interface

uses Windows, Contnrs, Sysutils,  Classes, Inifiles, RTLConsts,
     dialogs, Messages, JPEG, PNGImage, MD5, Graphics,  Lyrics,
     AudioFileBasics, NempFileUtils, AudioFiles,
     NempAudioFiles, AudioFileHelper, Nemp_ConstantsAndTypes, Hilfsfunktionen,
     HtmlHelper, Mp3FileUtils, ID3v2Frames,
     U_CharCode, gnuGettext, oneInst, StrUtils,  CoverHelper, BibHelper, StringHelper,
     Nemp_RessourceStrings, DriveRepairTools, ShoutcastUtils, BibSearchClass,
     NempCoverFlowClass, TagClouds, ScrobblerUtils, CustomizedScrobbler,
     DeleteHelper, TagHelper, Generics.Collections, unFastFileStream, System.Types, System.UITypes,
     Winapi.Wincodec, Winapi.ActiveX, System.Generics.Defaults;

const
    BUFFER_SIZE = 10 * 1024 * 1024;

type

    TLibraryLyricsUsage = record
        TotalFiles: Integer;
        FilesWithLyrics: Integer;
        TotalLyricSize: Integer;
    end;

    TDisplayContent = (DISPLAY_None, DISPLAY_BrowseFiles, DISPLAY_BrowsePlaylist, DISPLAY_Search, DISPLAY_Quicksearch, DISPLAY_Favorites);

    PDeadFilesInfo = ^TDeadFilesInfo;
    TDeadFilesInfo = record
        MissingDrives: Integer;
        ExistingDrives: Integer;
        MissingFilesOnMissingDrives: Integer;
        MissingFilesOnExistingDrives: Integer;
        MissingPlaylistsOnMissingDrives: Integer;
        MissingPlaylistsOnExistingDrives: Integer;
    end;

    // types for the automatic stuff to do after create.
    // note: When adding Jobs, ALWAYS add also a JOB_Finish job to finalize the process
    TJobType = (JOB_LoadLibrary, JOB_AutoScanNewFiles, JOB_AutoScanMissingFiles, JOB_StartWebServer, JOB_Finish);
    TStartJob = class
        public
            Typ: TJobType;
            Param: String;
            constructor Create(atype: TJobType; aParam: String);
            procedure Assign(aJob: TStartjob);
    end;
    TJobList = class(TObjectList<TStartJob>);

    TMedienBibliothek = class
    private
        MainWindowHandle: DWord;  // Handle of Nemp Main Window, Destination for all the messages

        // Thread-Handles
        fHND_LoadThread: DWord;
        fHND_UpdateThread: DWord;
        fHND_ScanFilesAndUpdateThread: DWord;
        fHND_DeleteFilesThread: DWord;
        fHND_RefreshFilesThread: DWord;
        fHND_GetLyricsThread: DWord;
        fHND_GetTagsThread: DWord;
        fHND_UpdateID3TagsThread: DWord;
        fHND_BugFixID3TagsThread: DWord;

        // filename for Thread-based loading
        fBibFilename: UnicodeString;

        // General note:
        //     all lists beginning with "tmp" are temporary lists, which stores the library
        //     during a update-process, so that the Application is blocked only for a very
        //     short time.
        Mp3ListePfadSort: TAudioFileList;      // List of all files in the library. Sorted by Path.
        tmpMp3ListePfadSort: TAudioFileList;   // Used for saving, searching and checking for new files

        Mp3ListeArtistSort:TAudioFileList;     // Two copies of the Mp3ListePfadSort, sorted by other criterias.
        Mp3ListeAlbenSort: TAudioFileList;     // used for fast browsing in the library.
        tmpMp3ListeArtistSort:TAudioFileList;
        tmpMp3ListeAlbenSort: TAudioFileList;

        DeadFiles: TAudioFileList;             // Two lists, that collect dead files
        DeadPlaylists: TObjectList;

        AlleAlben: TStringList;             // A list with all albums
        tmpAlleAlben: TStringList;          // (the list is shown in MainForm when selecting "All Artists")

        fDriveManager: TDriveManager; // managing the Drives used by the Library
        fPlaylistDriveManager: TDriveManager; // Another one for the Playlistfiles. Probably not needed in most cases


        PlaylistFiles: TAudioFileList;         // temporarly AudioFiles, loaded from Playlists

        AllPlaylistsPfadSort: TObjectList;     // Lists for Playlists.
        tmpAllPlaylistsPfadSort: TObjectList;  // Contain "TJustAString"-Objects
        AllPlaylistsNameSort: TObjectList;     // Same list, sorted by name for display

        fBackupCoverlist: TObjectList;  // Backup of the Coverlist, contains real Copies of the covers, not just pointers

        fIgnoreListCopy: TStringList;
        fMergeListCopy: TObjectList;

        // Status of the Library
        // Note: This is a legacy from older versions, e.g.
        //       No-ID3-Editing on status 1 is due to GetLyrics, where Tags are also
        //       written. This should be more fine grained.
        // But: Changing this now will probably cause more problems then solving ;-)
        //      Maybe later....
        //    0  Ok, everything is allowed
        //    1  awaiting Update (e.g. search for new files is running)
        //       or: another Thread is running on the library, editing some files
        //           the current file is sent to the VCL, so VCL can edit all files
        //           except this very special one.
        //       Adding/removing of files from the library is not allowed
        //       (duration: some minutes, up to 1/2 hour or so.)
        //    2  Update in progress. Do not write on lists (e.g. sorting)
        //       (usually the library is for 1-5 seconds in this state)
        //    3  Update in critical part
        //       Block Readaccess to the library
        //       (usually only a few mili-seconds)
        // IMPORTANT NOTE:
        //    DO NOT set the status except in the VCL-MainThread
        //    Status MUST be set via SendMessage from thread
        //    Status MUST NOT be set to 0 (zero) until the thread has finished
        //    A Thread MUST NOT be started, if the status is <> 0
        fStatusBibUpdate: Integer;

        // Thread-safe variable. DO NOT access it directly, always use the property
        fUpdateFortsetzen: LongBool;
        // another one, for scanning hard disk for new files (new in version 4.12.)
        fFileSearchAborted: LongBool;

        fArtist: UnicodeString;    // currently selected artist/album
        fAlbum: UnicodeString;     // Note: OnChange-Events of the trees MUST set these!
        fArtistIndex: Cardinal;
        fAlbumIndex: Cardinal;

        fChanged: LongBool;          // has bib changed? Is saving necessary?
        // Two helpers for Changed.
        // Loading a Library will execute the same code as adding new files.
        // On Startup a little different behaviour is wanted (e.g. the library is not changed)
        fChangeAfterUpdate: LongBool;
        // fInitializing: Integer; // not needed any more

        // After the user changes some information in an audiofile,
        // key1/2 and the matching "real information" are not identical.
        // As the "merge"-method is done by the real information, the old lists
        // must be resorted before merging.
        fBrowseListsNeedUpdate: Boolean;

        // Pfad zum Speicherverzeichnis - wird z.B. f�rs Kopieren der Cover ben�tigt.
        // Savepath:
        fSavePath: UnicodeString;        // ProgramDir or UserDir. used for Settings, Skins, ...
        // fCoverSavePath: UnicodeString;   // Path for Cover, := SavePath + 'Cover\'

        // The Flag for ignoring Lyrics in GetAudioData.
        // MUST be 0 (use Lyrics) or GAD_NOLYRICS (=8, ignore Lyrics)
        fIgnoreLyrics: Boolean;
        fIgnoreLyricsFlag: Integer;

        // (LYR_NONE, LYR_LYRICWIKI, LYR_CHARTLYRICS)
        // these temporary variables are set just before a Lyric-Search begins
        // they are computed from the priorities stored in the LyricPriorities-Array
        // !!! Access to these variables only within a CriticalSection !!!
        fLyricFirstPriority  : TLyricFunctionsEnum;
        fLyricSecondPriority : TLyricFunctionsEnum;

        // used for faster cover-initialisation.
        // i.e. do not search coverfiles for every audiofile.
        // use the same cover again, if the next audiofile is in the same directory
        // fLastCoverName: UnicodeString;
        // fLastPath: UnicodeString;
        // fLastID: String;    CoverArtSearcher

        // Browsemode
        // 0: Classic
        // 1: Coverflow
        // 2: Tagcloud
        fBrowseMode: Integer;
        fCoverSortOrder: Integer;

        fJobList: TJobList;

        function IsAutoSortWanted: Boolean;
        // Getter and Setter for some properties.
        // Most of them Thread-Safe
        function GetCount: Integer;
        procedure SetStatusBibUpdate(Value: Integer);
        function GetStatusBibUpdate   : Integer;
        procedure SetUpdateFortsetzen(Value: LongBool);
        function GetUpdateFortsetzen: LongBool;
        procedure SetFileSearchAborted(Value: LongBool);
        function GetFileSearchAborted: LongBool;
        function GetChangeAfterUpdate: LongBool;
        procedure SetChangeAfterUpdate(Value: LongBool);
        function GetChanged: LongBool;
        procedure SetChanged(Value: LongBool);
        function GetBrowseMode: Integer;
        procedure SetBrowseMode(Value: Integer);
        function GetCoverSortOrder: Integer;
        procedure SetCoverSortOrder(Value: Integer);

        procedure fSetIgnoreLyrics(aValue: Boolean);

        // Update-Process for new files, which has been collected before.
        // Runs in seperate Thread, sends proper messages to mainform for sync
        // 1. Prepare Update.
        //    - Merge Updatelist with MainList into tmpMainList
        //    - Create other tmp-Lists and -stuff and sort them
        procedure PrepareNewFilesUpdate;
        // 1b. Update UsedDriveList
        // procedure AddUsedDrivesInformation(aList: TObjectlist; aPlaylistList: TObjectList);
        // 2. Swap Lists, used on update-process
        procedure SwapLists;
        // 3. Clean tmp-lists, which are not needed after an update
        procedure CleanUpTmpLists;

        // Update-Process for Non-Existing Files.
        // Runs in seperate Thread, sends proper messages to mainform for sync
        // 1. Search Library for dead files
        Function fCollectDeadFiles: Boolean;
        // 1b. Let the user select files which should be deleted or not
//        procedure UserInputDeadFiles(DeleteDataList: TObjectList);
        // 2. Prepare Update
        //    - Fill tmplists with files, which are NOT dead

        procedure fPrepareDeleteFilesUpdate;
        // 3. Send Message and do
        //    CleanUpDeadFilesFromVCLLists
        //    in VCL-Thread
        // 4. Delete DeadFiles
        procedure fCleanUpDeadFiles;

        procedure fPrepareUserInputDeadFiles(DeleteDataList: TObjectList);
        procedure fReFillDeadFilesByDataList(DeleteDataList: TObjectList);
        procedure fGetDeadFilesSummary(DeleteDataList: TObjectList; var aSummary: TDeadFilesInfo);

        // Refreshing Library
        procedure fRefreshFiles(aRefreshList: TAudioFileList);      // 1a. Refresh files OR
        procedure fScanNewFiles;
        procedure fGetLyrics;         // 1b. get Lyrics
        procedure fPrepareGetTags;    // 1c. get tags, but at first make a copy of the Ignore/rename-Rules in VCL-Thread
        procedure fGetTags;           //     get Tags (from LastFM)
        procedure fUpdateId3tags;     // 2.  Write Library-Data into the id3-Tags (used in CloudEditor)
        procedure fBugFixID3Tags;     // BugFix-Method

        // ControlRawTag. Result: The new rawTag for the audiofile, including the previous existing
        //function ControlRawTag(af: TAudioFile; newTags: String; aIgnoreList: TStringList; aMergeList: TObjectList): String;

        // General Note:
        // "Artist" and "Album" are not necessary the artist and album, but
        // the two AudioFile-Properties selected for  browsing.
        // "Artist" ist the primary property (left), "Album" the secondary (right)

        // Get all Artists from the Library
        procedure GenerateArtistList(Source: TAudioFileList; Target: TObjectlist);
        // Get all Albums from the Library
        procedure InitAlbenlist(Source: TAudioFileList; Target: TStringList);
        // Get a Name-Sorted list of all Playlists
        // Note: No source-target-Parameter, as these lists are rather small.
        // No threaded tmp-list stuff needed here.
        // => call it AFTER swaplists
        procedure InitPlayListsList;

        procedure SortCoverList(aList: TObjectList);
        // Get all Cover from the Library (TNempCover, used for browsing)
        procedure GenerateCoverList(Source: TAudioFileList; Target: TObjectlist);

        procedure GenerateCoverListFromSearchResult(Source: TAudioFileList; Target: TObjectlist);


        // Helper for Browsing Between
        // "Start" and "Ende" are the files with the wanted "Name"
        procedure GetStartEndIndex(Liste: TAudioFileList; name: UnicodeString; Suchart: integer; var Start: integer; var Ende: Integer);
        procedure GetStartEndIndexCover(Liste: TAudioFileList; aCoverID: String; var Start: integer; var Ende: Integer);

        // Helper for "FillRandomList"
        function CheckYearRange(Year: UnicodeString): Boolean;
        //function CheckGenrePL(Genre: UnicodeString): Boolean;
        function CheckRating(aRating: Byte): Boolean;
        function CheckLength(aLength: Integer): Boolean;
        function CheckTags(aTagList: TObjectList): Boolean;

        // Synch a List of TDrives with the current situation on the PC
        // i.e. Search the Drive-IDs in the system and adjust the drive-letters
        // procedure SynchronizeDrives(Source: TObjectList);
        // Check whether drive has changed after a new device has been connected
        // function DrivesHaveChanged: Boolean;

        // Saving/loading the *.gmp-File
        function LoadDrivesFromStream_DEPRECATED(aStream: TStream): Boolean;
        function LoadDrivesFromStream(aStream: TStream): Boolean;
        procedure SaveDrivesToStream(aStream: TStream);

        function LoadAudioFilesFromStream_DEPRECATED(aStream: TStream; MaxSize: Integer): Boolean;
        function LoadAudioFilesFromStream(aStream: TStream): Boolean;
        procedure SaveAudioFilesToStream(aStream: TStream; StreamFilename: String);

        function LoadPlaylistsFromStream_DEPRECATED(aStream: TStream): Boolean;
        function LoadPlaylistsFromStream(aStream: TStream): Boolean;
        procedure SavePlaylistsToStream(aStream: TStream; StreamFilename: String);

        function LoadRadioStationsFromStream_DEPRECATED(aStream: TStream): Boolean;
        function LoadRadioStationsFromStream(aStream: TStream): Boolean;
        procedure SaveRadioStationsToStream(aStream: TStream);

        procedure LoadFromFile4(aStream: TStream; SubVersion: Integer);

        // new format since Nemp 4.13 (end of 2019)
        procedure LoadFromFile5(aStream: TStream; SubVersion: Integer);

        procedure fLoadFromFile(aFilename: UnicodeString);

    public
        CloseAfterUpdate: Boolean; // flag used in OnCloseQuery
        // Some Beta-Options
        //BetaDontUseThreadedUpdate: Boolean;

        // Diese Objekte werden in der linken Vorauswahlspalte angezeigt.
        AlleArtists: TObjectList;
        tmpAlleArtists: TObjectList;

        Coverlist: tObjectList;
        tmpCoverlist: tObjectList;

        // Die Alben, die in der rechten Vorauswahl-Spalte angezeigt werden.
        // wird im Onchange der linken Spalte aktualisiert
        Alben: TObjectList;

        // Liste, die unten in der Liste angezeigt wird.
        // wird generiert �ber Onchange der Vorauswahl, oder aber von der Such-History
        // Achtung: Auf diese NUR IM VCL-HAUPTTHREAD zugreifen !!

        ///  *************************
        ///  Rework 2018:
        ///  - Three "Real" Lists, which actually stores AudioFileObjects
        ///    a. LastBrowseResult (for Browsing, Coverflow, TagCloud and "big" search)
        ///    b. LastQuickSearchResult (for Quicksearch)
        ///    c. LastMarkFilter (for switching between files with different marks)
        ///  - Two "Virtual" Lists, which are only links to one of the two above
        ///    * AnzeigeListe (pointer to a. or b. or c.), which is displayed in the VST
        ///    * BaseMarkerList (pointer to a. or b. or "all files" (user setting))
        ///
        ///  maybe later: replace "AnzeigeShowsPlaylistFiles" by another "PlaylistFilesList" ??
        ///  ************************
        LastBrowseResultList      : TAudioFileList;
        LastQuickSearchResultList : TAudioFileList;
        LastMarkFilterList        : TAudioFileList;
        // virtual Lists, do NOT create/free. These are just links to one of three above (or "allFiles")
        AnzeigeListe          : TAudioFileList;
        BaseMarkerList        : TAudioFileList;
        // AnzeigeListe2: TObjectList; // Speichert zus�tzliche QuickSearch-Resultate.
        // Flag, was f�r Dateien in der Playlist sind
        // Muss bei jeder �nderung der AnzeigeListe gesetzt werden
        // Zus�tzlich d�rfen Dateien aus der AnzeigeListe ggf. nicht in andere Listen geh�ngt werden.
        AnzeigeShowsPlaylistFiles: Boolean;

        DisplayContent: TDisplayContent;

        // Liste f�r die Webradio-Stationen
        // Darauf greift auch die Stream-Verwaltung-Form zu
        // Objekte darin sind von Typ TStation
        RadioStationList: TObjectlist;

        // Liste, in die die neu einzupflegenden Dateien kommen
        // Auf diese Liste greift Searchtool zu, wenn die Platte durchsucht wird,
        // und auch die Laderoutine
        UpdateList: TAudioFileList;

        ///  PlaylistUpdateList: With the new system since Nemp 4.14 we need 2 Lists
        ///  for Playlists during the UpdateProcess
        ///  PlaylistUpdateList_Playlist contains the PlaylistObjects with DriveID from the LibraryFile.
        ///                              These objects need to be processed after Loading is complete
        ///  PlaylistUpdateList: During processing these Objects, we create the "JustAString"-objects, we actually
        ///                      use in the Library
        PlaylistUpdateList: TObjectList;
        PlaylistUpdateList_Playlist: TObjectList;

        // Speichert die zu durchsuchenden Ordner f�r SearchTool
        ST_Ordnerlist: TStringList;

        PlaylistFillOptions: TPlaylistFillOptions;

        // Optionen, die aus der Ini kommen/gespeichert werden m�ssen
        NempSortArray: TNempSortArray;
        IncludeAll: Boolean;
        IncludeFilter: String; // a string like "*.mp3;*.ogg;*.wma" - replaces the old Include*-Vars
        
        AutoLoadMediaList: Boolean;
        AutoSaveMediaList: Boolean;
        alwaysSortAnzeigeList: Boolean;
        limitMarkerToCurrentFiles: Boolean;
        SkipSortOnLargeLists: Boolean;
        AnzeigeListIsCurrentlySorted: Boolean;
        AutoScanPlaylistFilesOnView: Boolean;
        ShowHintsInMedialist: Boolean;
        AutoScanDirs: Boolean;
        AutoScanDirList: TStringList;  // complete list of all Directories to scan
        AutoScanToDoList: TStringList; // the "working list"

        CurrentSearchDir: String;

        // for the scan process for new files: New method in 4.12
        UseNewFileScanMethod: Boolean;

        AutoDeleteFiles: Boolean;       
        AutoDeleteFilesShowInfo: Boolean;

        InitialDialogFolder: String;  // last used folder for "scan for audiofiles"

        // Bei neuen Ordnern (per Drag&Drop o.�.) Dialog anzeigen, ob sie in die Auto-Liste eingef�gt werden sollen
        AskForAutoAddNewDirs: Boolean;
        // Automatisch neue Ordner in die Scanlist einf�gen
        AutoAddNewDirs: Boolean;

        AutoActivateWebServer: Boolean;

        CoverSearchLastFM: Boolean;
        HideNACover: Boolean;
        MissingCoverMode: Integer;

        // Einstellungen f�r Standard-Cover
        // Eines f�r alle. Ist eins nicht da: Fallback auf Default
        //UseNempDefaultCover: Boolean;
        //PersonalizeMainCover: Boolean;

        // zur Laufzeit - weitere Sortiereigenschaften
        //Sortparam: Integer; // Eine der CON_ // CON_EX_- Konstanten
        //SortAscending: Boolean;

        SortParams: Array[0..SORT_MAX] of TCompareRecord;
          { TODO :
            SortParams im Create initialisieren
            SortParams in Ini Speichern/Laden }

        LyricPriorities: Array[TLyricFunctionsEnum] of Integer;

        // this is used to synchronize access to single mediafiles
        // Some threads are running and modifying the files: GetLyrics and the Player.PostProcessor
        // This is fine, but the VCL MUST NOT try to write the same files.
        // So, the threads send a message to the vcl with the filename as (w/l)Param
        // and when the user wants to set the info manually the vcl must test this variable!
        // (this is necessary on status 1)
        CurrentThreadFilename: UnicodeString;

        BibSearcher: TBibSearcher;

        // The Currently selected File in the Treeview.
        // used for editing-stuff in the detail-panel besides the tree
        // Note: This File is not necessary in the library. It can be just in
        // the playlist! Or one entry in a Library-Playlist.
        CurrentAudioFile: TAudioFile;


        NewCoverFlow: TNempCoverFlow;

        TagCloud: TTagCloud;
        TagPostProcessor: TTagPostProcessor;
        AskForAutoResolveInconsistencies: Boolean;
        ShowAutoResolveInconsistenciesHints: Boolean;
        AutoResolveInconsistencies: Boolean;

        AskForAutoResolveInconsistenciesRules: Boolean;
        AutoResolveInconsistenciesRules: Boolean;
        //ShowAutoResolveInconsistenciesHints: Boolean;

        // BibScrobbler: Link to Player.NempScrobbler
        BibScrobbler: TNempScrobbler;


        CoverArtSearcher: TCoverArtSearcher;


        property StatusBibUpdate   : Integer read GetStatusBibUpdate    write SetStatusBibUpdate;

        property Count: Integer read GetCount;

        property CurrentArtist: UnicodeString read fArtist write fArtist;
        property CurrentAlbum: UnicodeString read fAlbum write fAlbum;

        property ArtistIndex: Cardinal read fArtistIndex write fArtistIndex;
        property AlbumIndex: Cardinal read fAlbumIndex write fAlbumIndex;
        property Changed: LongBool read GetChanged write SetChanged;
        property ChangeAfterUpdate: LongBool read GetChangeAfterUpdate write SetChangeAfterUpdate;
        property BrowseMode: Integer read GetBrowseMode write SetBrowseMode;
        property CoverSortOrder: Integer read GetCoverSortOrder write SetCoverSortOrder;

        property UpdateFortsetzen: LongBool read GetUpdateFortsetzen Write SetUpdateFortsetzen;
        property FileSearchAborted: LongBool read GetFileSearchAborted write SetFileSearchAborted;

        property SavePath: UnicodeString read fSavePath write fSavePath;

        property IgnoreLyrics     : Boolean read fIgnoreLyrics     write fSetIgnoreLyrics  ;
        property IgnoreLyricsFlag : Integer read fIgnoreLyricsFlag                         ;

        property PlaylistDriveManager: TDriveManager read fPlaylistDriveManager;

        // Basic Operations. Create, Destroy, Clear, Copy
        constructor Create(aWnd: DWord; CFHandle: DWord);
        destructor Destroy; override;
        procedure Clear;
        // Copy The Files from the Library for use in WebServer
        // Note: WebServer will run multiple threads, but read-access only.
        //       Sync with main program will be complicated, so the webserver uses
        //       a copy of the list.
        procedure CopyLibrary(dest: TAudioFileList; var CurrentMaxID: Integer);
        // Load/Save options into IniFile
        procedure LoadFromIni(ini: TMemIniFile);
        procedure WriteToIni(ini: TMemIniFile);

        // Managing the Library
        // - Merging new Files into the library (Param NewBib=True on loading a new library
        //                                       false otherwise)
        // - Delete not existing files
        // - Refresh AudioFile-Information
        // - Automatically get Lyrics from LyricWiki.org
        // These methods will start a new thread and call several private methods
        procedure NewFilesUpdateBib(NewBib: Boolean = False);
        procedure DeleteFilesUpdateBib;
        procedure DeleteFilesUpdateBibAutomatic;

        // for Nemp 4.12: Scan Files in UpdateList for the first time and merge them into the MediaLibrary
        procedure ScanNewFilesAndUpdateBib;

        procedure CleanUpDeadFilesFromVCLLists;
        procedure RefreshFiles_All;
        procedure RefreshFiles_Selected;
        procedure GetLyricPriorities(out Prio1, Prio2: TLyricFunctionsEnum);
        procedure GetLyrics;
        procedure GetTags;
        procedure UpdateId3tags;
        procedure BugFixID3Tags;

        // Additional managing. Run in VCL-Thread.
        procedure BuildTotalString;
        procedure BuildTotalLyricString;
        function DeleteAudioFile(aAudioFile: tAudioFile): Boolean;
        function DeletePlaylist(aPlaylist: TJustAString): Boolean;
        procedure Abort;        // abort running update-threads
        //////procedure ResetRatings;
        // Check, whether Key1 and Key2 matches strings[sortarray[1/2]]
        function ValidKeys(aAudioFile: TAudioFile): Boolean;
        // set fBrowseListsNeedUpdate to true
        procedure ChangeCoverID(oldID, newID: String);
        procedure HandleChangedCoverID;

        procedure ChangeCoverIDUnsorted(oldID, newID: String);

        procedure ProcessLoadedFilenames;
        procedure ProcessLoadedPlaylists;

        // even more stuff for file managing: Additional Tags
        function AddNewTagConsistencyCheck(aAudioFile: TAudioFile; newTag: String): TTagConsistencyError;
        function AddNewTag(aAudioFile: TAudioFile; newTag: String; IgnoreWarnings: Boolean; Threaded: Boolean = False): TTagError;
        //procedure RemoveTag(aAudioFile: TAudioFile; oldTag: String);

        // Not needed any longer
        // function RestoreSortOrderAfterItemChanged(aAudioFile: tAudioFile): Boolean;

        // Check, whether AudioFiles already exists in the library.
        function AudioFileExists(aFilename: UnicodeString): Boolean;
        function GetAudioFileWithFilename(aFilename: UnicodeString): TAudioFile;
        function PlaylistFileExists(aFilename: UnicodeString): Boolean;

        // 2018: new helper method to set the BaseMarkerList properly
        procedure SetBaseMarkerList(aList: TAudioFileList);

        // Methods for Browsing in the Library
        // 1. Generate BrowseLists
        //    see private methods, called during update-process
        // 2. Regenerate BrowseLists
        Procedure ReBuildBrowseLists;     // Complete Rebuild
        procedure ReBuildCoverList(FromScratch: Boolean = True);       // -"- of CoverLists
        procedure ReBuildCoverListFromList(aList: TAudioFileList);  // used to refresh coverflow on QuickSearch
        procedure ReBuildTagCloud;        // -"- of the TagCloud

        procedure GetTopTags(ResultCount: Integer; Offset: Integer; Target: TObjectList; HideAutoTags: Boolean = False);
        procedure RestoreTagCloudNavigation;
        procedure RepairBrowseListsAfterDelete; // Rebuild, but sorting is not needed
        procedure RepairBrowseListsAfterChange; // Another Repair-method :?
        // 3. When Browsing the left tree, fill the right tree
        procedure GetAlbenList(Artist: UnicodeString);
        // 4. Get from a selected pair of "Artist"-"Album" the matching titles
        Procedure GetTitelList(Target: TAudioFileList; Artist: UnicodeString; Album: UnicodeString);
        // Ruft nur GetTitelList auf, mit Target = AnzeigeListe
        // NUR IM VCL_HAUPTTHREAD benutzen
        Procedure GenerateAnzeigeListe(Artist: UnicodeString; Album: UnicodeString);// UpdateQuickSearchList: Boolean = True);
        // wie oben, nur wirdf hier nur auf eine der gro�en Listen zugegriffen
        // und die Sortierung ist immer nach CoverID, kein zweites Kriterium m�glich.
        procedure GetTitelListFromCoverID(Target: TAudioFileList; aCoverID: String);
        procedure GetTitelListFromCoverIDUnsorted(Target: TAudioFileList; aCoverID: String);
        procedure GetTitelListFromDirectoryUnsorted(Target: TAudioFileList; aDirectory: String);
        procedure GenerateAnzeigeListeFromCoverID(aCoverID: String);
        procedure GenerateAnzeigeListeFromTagCloud(aTag: TTag; BuildNewCloud: Boolean);
        procedure GenerateDragDropListFromTagCloud(aTag: TTag; Target: TAudioFileList);

        procedure RestoreAnzeigeListeAfterQuicksearch;

        // Search the next matching cover
        function GetCoverWithPrefix(aPrefix: UnicodeString; Startidx: Integer): Integer;

        // Methods for searching
        // See BibSearcherClass for Details.
        ///Procedure ShowQuickSearchList;  // Displays the QuicksearchList
        ///procedure FillQuickSearchList;  // Set the currently displayed List as QuickSearchList
        // Searching for keywords
        // a. Quicksearch
        procedure GlobalQuickSearch(Keyword: UnicodeString; AllowErr: Boolean);
        procedure IPCSearch(Keyword: UnicodeString);
        // special case: Searching for a Tag
        procedure GlobalQuickTagSearch(KeyTag: UnicodeString);
        // search for '*' => show all files in the library
        procedure QuickSearchShowAllFiles;

        // b. detailed search
        procedure CompleteSearch(Keywords: TSearchKeyWords);
        procedure CompleteSearchNoSubStrings(Keywords: TSearchKeyWords);
        // c. get all files from the library in the same directory
        procedure GetFilesInDir(aDirectory: UnicodeString; ClearExistingView: Boolean);
        // d. Special case: Search for Empty Strings
        procedure EmptySearch(Mode: Integer);
        // list favorites
        procedure ShowMarker(aIndex: Byte);

        // Sorting the Lists
        procedure AddSorter(TreeHeaderColumnTag: Integer; FlipSame: Boolean = True);
        procedure SortAnzeigeListe;

        // Generating RandomList (Random Playlist)
        procedure FillRandomList(aList: TAudioFileList);

        // copy all files into another list (used for counting ratings)
        procedure FillListWithMedialibrary(aList: TAudioFileList);

        // Helper for AutoScan-Directories
        function ScanListContainsParentDir(NewDir: UnicodeString):UnicodeString;
        function ScanListContainsSubDirs(NewDir: UnicodeString):UnicodeString;
        Function JobListContainsNewDirs(aJobList: TStringList): Boolean;

        // Resync drives when connecting new devices to the computer
        // Return value: Something has changed (True) or no changes (False)
        function ReSynchronizeDrives: Boolean;
        // Change the paths of all AudioFiles according to the new situation
        procedure RepairDriveCharsAtAudioFiles;
        procedure RepairDriveCharsAtPlaylistFiles;

        // Managing webradio in the Library
        procedure ExportFavorites(aFilename: UnicodeString);
        procedure ImportFavorites(aFilename: UnicodeString);
        function AddRadioStation(aStation: TStation): Integer;

        // Saving/Loading
        // a. Export as CSV, to get the library to Excel or whatever.
        function SaveAsCSV(aFilename: UnicodeString): Boolean;
        // b. Loading/Saving the *.gmp-File
        // will call several private methods
        procedure SaveToFile(aFilename: UnicodeString; Silent: Boolean = True);
        procedure LoadFromFile(aFilename: UnicodeString; Threaded: Boolean = False);

        function CountInconsistentFiles: Integer;      // Count "ID3TagNeedsUpdate"-AudioFiles
        procedure PutInconsistentFilesToUpdateList;    // Put these files into the updatelist
        procedure PutAllFilesToUpdateList;    // Put these files into the updatelist
        function ChangeTags(oldTag, newTag: String): Integer;
        function CountFilesWithTag(aTag: String): Integer;

        // function GetDriveFromUsedDrives(aChar: Char): TDrive;

        // note: When adding Jobs, ALWAYS add also a JOB_Finish job to finalize the process
        procedure AddStartJob(aJobtype: TJobType; aJobParam: String);
        procedure ProcessNextStartJob;

        function GetLyricsUsage: TLibraryLyricsUsage;
        procedure RemoveAllLyrics;

  end;

  Procedure fLoadLibrary(MB: TMedienbibliothek);
  Procedure fNewFilesUpdate(MB: TMedienbibliothek);
  procedure fScanNewFilesAndUpdateBib(MB: TMedienbibliothek);

  Procedure fDeleteFilesUpdateContainer(MB: TMedienbibliothek; askUser: Boolean);
  Procedure fDeleteFilesUpdateUser(MB: TMedienbibliothek);
  Procedure fDeleteFilesUpdateAutomatic(MB: TMedienbibliothek);

  procedure fRefreshFilesThread_All(MB: TMedienbibliothek);
  procedure fRefreshFilesThread_Selected(MB: TMedienbibliothek);

  procedure fGetLyricsThread(MB: TMedienBibliothek);
  procedure fGetTagsThread(MB: TMedienBibliothek);

  procedure fUpdateID3TagsThread(MB: TMedienBibliothek);
  procedure fBugFixID3TagsThread(MB: TMedienBibliothek);

  function GetProperMenuString(aIdx: Integer): UnicodeString;

  var //CSStatusChange: RTL_CRITICAL_SECTION;
      CSUpdate: RTL_CRITICAL_SECTION;
      CSAccessDriveList: RTL_CRITICAL_SECTION;
      CSAccessBackupCoverList: RTL_CRITICAL_SECTION;
      CSLyricPriorities: RTL_CRITICAL_SECTION;

implementation

uses fspTaskBarMgr;

function GetProperMenuString(aIdx: Integer): UnicodeString;
begin
    case aIdx of
        0: result := MainForm_MenuCaptionsEnqueueAllArtist   ;
        1: result := MainForm_MenuCaptionsEnqueueAllAlbum    ;
        2: result := MainForm_MenuCaptionsEnqueueAllDirectory;
        3: result := MainForm_MenuCaptionsEnqueueAllGenre    ;
        4: result := MainForm_MenuCaptionsEnqueueAllYear     ;
        5: result := MainForm_MenuCaptionsEnqueueAllDate     ;
        6: result := MainForm_MenuCaptionsEnqueueAllTag      ;
    else
        result := '(?)'
    end;
end;


constructor TStartJob.Create(atype: TJobType; aParam: String);
begin
    Typ := atype;
    Param := aParam;
end;

procedure TStartJob.Assign(aJob: TStartjob);
begin
    self.Typ := aJob.Typ;
    self.Param := aJob.Param;
end;

{
    --------------------------------------------------------
    Create, Destroy
    Create/Free all the lists
    --------------------------------------------------------
}
constructor TMedienBibliothek.Create(aWnd: DWord; CFHandle: DWord);
var i: Integer;
begin
  inherited create;
  CloseAfterUpdate := False;
  MainWindowHandle := aWnd;

  Mp3ListePfadSort   := TAudioFileList.Create(False);
  Mp3ListeArtistSort := TAudioFileList.create(False);
  Mp3ListeAlbenSort  := TAudioFileList.create(False);
  tmpMp3ListePfadSort   := TAudioFileList.Create(False);
  tmpMp3ListeArtistSort := TAudioFileList.create(False);
  tmpMp3ListeAlbenSort  := TAudioFileList.create(False);

  DeadFiles := TAudioFileList.create(False);
  DeadPlaylists := TObjectlist.create(False);

  AlleAlben := TStringList.Create;
  tmpAlleAlben := TStringList.Create;
  AlleArtists  := TObjectlist.create(False);
  tmpAlleArtists  := TObjectlist.create(False);
  Coverlist := tObjectList.create(False);
  fBackupCoverlist := TObjectList.Create; // Destroy Objects when clearing this list
  tmpCoverlist := tObjectList.create(False);

  fIgnoreListCopy := TStringList.Create;
  fMergeListCopy := TObjectList.Create;


  Alben        := TObjectlist.create(False);


  LastBrowseResultList      := TAudioFileList.create(False);
  LastQuickSearchResultList := TAudioFileList.create(False);
  LastMarkFilterList        := TAudioFileList.create(False);
  // virtual Lists, do NOT create/free
  AnzeigeListe              := LastBrowseResultList;
  BaseMarkerList            := LastBrowseResultList;

  AnzeigeShowsPlaylistFiles := False;
  DisplayContent := DISPLAY_None;

  BibSearcher := TBibSearcher.Create(aWnd);
  BibSearcher.MainList := Mp3ListePfadSort;

  RadioStationList    := TObjectlist.Create;
  UpdateList   := TAudioFileList.create(False);
  ST_Ordnerlist := TStringList.Create;
  AutoScanDirList := TStringList.Create;
  AutoScanDirList.Sorted := True;
  AutoScanToDoList := TStringList.Create;

  fDriveManager := TDriveManager.Create;
  fPlaylistDriveManager := TDriveManager.Create;

  PlaylistFiles := TAudioFileList.Create(True);
  tmpAllPlaylistsPfadSort := TObjectList.Create(False);
  AllPlaylistsPfadSort := TObjectList.Create(False);
  AllPlaylistsNameSort := TObjectList.Create(False);
  PlaylistUpdateList := TObjectList.Create(False);
  PlaylistUpdateList_Playlist := TObjectList.Create(True);

  NempSortArray[1] := siOrdner;//Artist;
  NempSortArray[2] := siArtist;

  //SortParam := CON_ARTIST;
  //SortAscending := True;
  Changed := False;
  //Initializing := init_nothing;

  CurrentArtist := BROWSE_ALL;
  CurrentAlbum := BROWSE_ALL;
  for i := 0 to SORT_MAX  do
        begin
            SortParams[i].Comparefunction := AFComparePath;
            SortParams[i].Direction := sd_Ascending;
            SortParams[i].Tag := CON_PFAD;
        end;

  NewCoverFlow := TNempCoverFlow.Create;// (CFHandle, aWnd);

  CoverArtSearcher := TCoverArtSearcher.Create;

  TagCloud := TTagCloud.Create;
  TagPostProcessor := TTagPostProcessor.Create; // Data files are loaded automatically

  fJobList := TJobList.Create;
  fJobList.OwnsObjects := True;
end;

destructor TMedienBibliothek.Destroy;
var i: Integer;
begin

  fJobList.Free;
  NewCoverFlow.free;
  fIgnoreListCopy.Free;
  fMergeListCopy.Free;

  TagPostProcessor.Free;
  TagCloud.Free;

  CoverArtSearcher.Free;

  for i := 0 to Mp3ListePfadSort.Count - 1 do
      Mp3ListePfadSort[i].Free;

  Mp3ListePfadSort.Free;
  Mp3ListeArtistSort.Free;
  Mp3ListeAlbenSort.Free;

  tmpMp3ListePfadSort.Free;
  tmpMp3ListeArtistSort.Free;
  tmpMp3ListeAlbenSort.Free;

  DeadFiles.Free;
  DeadPlaylists.Free;

  AlleAlben.Free;
  tmpAlleAlben.Free;

  for i := 0 to tmpAlleArtists.Count - 1 do
    TJustaString(tmpAlleArtists[i]).Free;
  for i := 0 to AlleArtists.Count - 1 do
    TJustaString(AlleArtists[i]).Free;
  for i := 0 to Alben.Count - 1 do
    TJustaString(Alben[i]).Free;
  for i := 0 to Coverlist.Count - 1 do
    TNempCover(CoverList[i]).Free;
  for i := 0 to tmpCoverlist.Count - 1 do
    TNempCover(tmpCoverlist[i]).Free;
  for i := 0 to AllPlaylistsPfadSort.Count - 1 do
      TJustaString(AllPlaylistsPfadSort[i]).Free;

  AutoScanDirList.Free;
  AutoScanToDoList.Free;
      EnterCriticalSection(CSAccessDriveList);
      fDriveManager.Free;
      fPlaylistDriveManager.Free;
      LeaveCriticalSection(CSAccessDriveList);
  PlaylistFiles.Free;
  tmpAllPlaylistsPfadSort.Free;
  AllPlaylistsNameSort.Free;
  AllPlaylistsPfadSort.Free;

  RadioStationList.Free;

  tmpAlleArtists.Free;
  AlleArtists.Free;
  Alben.Free;

  LastBrowseResultList      .Free;
  LastQuickSearchResultList .Free;
  LastMarkFilterList        .Free;
  // virtual Lists, do NOT create/free
  AnzeigeListe          := Nil;
  BaseMarkerList        := Nil;

  UpdateList.Free;
  PlaylistUpdateList.Free;
  PlaylistUpdateList_Playlist.Free;
  ST_Ordnerlist.Free;
  tmpCoverlist.Free;
  Coverlist.Free;
  fBackupCoverlist.Free;
  BibSearcher.Free;

  inherited Destroy;
end;


{
    --------------------------------------------------------
    Clear
    Clear the lists, free the AudioFiles
    --------------------------------------------------------
}
procedure TMedienBibliothek.Clear;
var i: Integer;
begin
  fJobList.Clear;
  for i := 0 to Mp3ListePfadSort.Count - 1 do
      Mp3ListePfadSort[i].Free;

  Mp3ListePfadSort.Clear;
  Mp3ListeArtistSort.Clear;
  Mp3ListeAlbenSort.Clear;
  tmpMp3ListePfadSort.Clear;
  tmpMp3ListeArtistSort.Clear;
  tmpMp3ListeAlbenSort.Clear;
  DeadFiles.Clear;
  DeadPlaylists.Clear;

  UpdateList.Clear;
  PlaylistUpdateList.Clear;
  PlaylistUpdateList_Playlist.Clear;
  ST_Ordnerlist.Clear;

  EnterCriticalSection(CSAccessDriveList);
  fDriveManager.Clear;
  fPlaylistDriveManager.Clear;
  LeaveCriticalSection(CSAccessDriveList);

  AlleAlben.Clear;
  tmpAlleAlben.Clear;

  for i := 0 to tmpAlleArtists.Count - 1 do
    TJustaString(tmpAlleArtists[i]).Free;
  for i := 0 to AlleArtists.Count - 1 do
    TJustaString(AlleArtists[i]).Free;
  for i := 0 to Alben.Count - 1 do
    TJustaString(Alben[i]).Free;
  for i := 0 to Coverlist.Count - 1 do
    TNempCover(CoverList[i]).Free;
  for i := 0 to tmpCoverlist.Count - 1 do
    TNempCover(tmpCoverlist[i]).Free;
  for i := 0 to AllPlaylistsPfadSort.Count - 1 do
      TJustaString(AllPlaylistsPfadSort[i]).Free;

  tmpAllPlaylistsPfadSort.Clear;
  AllPlaylistsPfadSort.Clear;
  AllPlaylistsNameSort.Clear;
  PlaylistFiles.Clear;
  tmpAlleArtists.Clear;
  AlleArtists.Clear;
  Alben.Clear;

  LastBrowseResultList      .Clear;
  LastQuickSearchResultList .Clear;
  LastMarkFilterList        .Clear;

  AnzeigeShowsPlaylistFiles := False;
  DisplayContent := DISPLAY_None;

  BibSearcher.Clear;
  Coverlist.Clear;
  tmpCoverlist.Clear;

  NewCoverFlow.clear;

  CoverArtSearcher.Clear;
  RadioStationList.Clear;
  RepairBrowseListsAfterDelete;
  AnzeigeListIsCurrentlySorted := False;
  SendMessage(MainWindowHandle, WM_MedienBib, MB_RefillTrees, 0);
  SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList, 0);
end;
{
    --------------------------------------------------------
    CopyLibrary
    - Copy the list for use in Webserver
    --------------------------------------------------------
}
procedure TMedienBibliothek.CopyLibrary(dest: TAudioFileList; var CurrentMaxID: Integer);
var i: Integer;
    newAF, AF: TAudioFile;
begin
  if StatusBibUpdate <> BIB_Status_ReadAccessBlocked then
  begin
      dest.Clear;
      dest.Capacity := Mp3ListePfadSort.Count;
      for i := 0 to Mp3ListePfadSort.Count - 1 do
      begin
          AF := Mp3ListePfadSort[i];
          newAF := TAudioFile.Create;
          newAF.AssignLight(AF); // d.h. ohne Lyrics!
          if AF.WebServerID = 0 then
          begin
              AF.WebServerID := CurrentMaxID;
              newAF.WebServerID := CurrentMaxID;
              inc(CurrentMaxID);
          end else
              newAF.WebServerID := AF.WebServerID;
          dest.Add(newAF);
      end;
  end;// else
      // wuppdi;
end;

{
    --------------------------------------------------------
    CountInconsistentFiles
    - Count "ID3TagNeedsUpdate"-AudioFiles
      VCL-Thread only!
    --------------------------------------------------------
}
function TMedienBibliothek.CountInconsistentFiles: Integer;
var i, c: Integer;
begin
    c := 0;
    for i := 0 to Mp3ListePfadSort.Count - 1 do
        if Mp3ListePfadSort[i].ID3TagNeedsUpdate then
            inc(c);
    result := c;
end;
{
    --------------------------------------------------------
    PutInconsistentFilesToUpdateList
    - Put these Files into the Update-List
      Runs in VCL-MainThread!
    --------------------------------------------------------
}
procedure TMedienBibliothek.PutInconsistentFilesToUpdateList;
var i: integer;
begin
    UpdateList.Clear;
    for i := 0 to Mp3ListePfadSort.Count - 1 do
    begin
        if MP3ListePfadSort[i].ID3TagNeedsUpdate then
            UpdateList.Add(MP3ListePfadSort[i]);
    end;
end;
{
    --------------------------------------------------------
    PutAllFilesToUpdateList
    - Put all Files into the Update-List
      Used for ID3Bugfix
    --------------------------------------------------------
}
procedure TMedienBibliothek.PutAllFilesToUpdateList;
var i: integer;
begin
    UpdateList.Clear;
    for i := 0 to Mp3ListePfadSort.Count - 1 do
        UpdateList.Add(MP3ListePfadSort[i]);
end;


function TMedienBibliothek.ChangeTags(oldTag, newTag: String): Integer;
var i, c: Integer;
begin
    result := 0;
    if StatusBibUpdate >= 2 then exit;
    c := 0;
    for i := 0 to Mp3ListePfadSort.Count - 1 do
        if Mp3ListePfadSort[i].ChangeTag(oldTag, newTag) then
            inc(c);
    result := c;
end;

function TMedienBibliothek.CountFilesWithTag(aTag: String): Integer;
var i, c: Integer;
begin
    result := 0;
    if StatusBibUpdate >= 2 then exit;
    c := 0;
    for i := 0 to Mp3ListePfadSort.Count - 1 do
        if Mp3ListePfadSort[i].ContainsTag(aTag) then
            inc(c);
    result := c;
end;

{
    --------------------------------------------------------
    Setter/Getter for some properties.
    Most of them Threadsafe, as they are needed in VCL and secondary thread
    --------------------------------------------------------
}
function TMedienBibliothek.GetCount: Integer;
begin
  result := Mp3ListePfadSort.Count;
end;
procedure TMedienBibliothek.SetStatusBibUpdate(Value: Integer);
begin
  InterLockedExchange(fStatusBibUpdate, Value);
end;
function TMedienBibliothek.GetStatusBibUpdate   : Integer;
begin
  InterLockedExchange(Result, fStatusBibUpdate);
end;
function TMedienBibliothek.GetChangeAfterUpdate: LongBool;
begin
  InterLockedExchange(Integer(Result), Integer(fChangeAfterUpdate));
end;
procedure TMedienBibliothek.SetChangeAfterUpdate(Value: LongBool);
begin
  InterLockedExchange(Integer(fChangeAfterUpdate), Integer(Value));
end;
function TMedienBibliothek.GetChanged: LongBool;
begin
  InterLockedExchange(Integer(Result), Integer(fChanged));
end;
procedure TMedienBibliothek.SetChanged(Value: LongBool);
begin
  InterLockedExchange(Integer(fChanged), Integer(Value));
end;
function TMedienBibliothek.GetBrowseMode: Integer;
begin
  InterLockedExchange(Result, fBrowseMode);
end;
procedure TMedienBibliothek.SetBrowseMode(Value: Integer);
begin
  InterLockedExchange(fBrowseMode, Value);
end;
function TMedienBibliothek.GetCoverSortOrder: Integer;
begin
  InterLockedExchange(Result, fCoverSortOrder);
end;
procedure TMedienBibliothek.SetCoverSortOrder(Value: Integer);
begin
  InterLockedExchange(fCoverSortOrder, Value);
end;
procedure TMedienBibliothek.SetUpdateFortsetzen(Value: LongBool);
begin
  InterLockedExchange(Integer(fUpdateFortsetzen), Integer(Value));
end;
function TMedienBibliothek.GetUpdateFortsetzen: LongBool;
begin
  InterLockedExchange(Integer(Result), Integer(fUpdateFortsetzen));
end;
procedure TMedienBibliothek.SetFileSearchAborted(Value: LongBool);
begin
    InterLockedExchange(Integer(fFileSearchAborted), Integer(Value));
end;
function TMedienBibliothek.GetFileSearchAborted: LongBool;
begin
    InterLockedExchange(Integer(Result), Integer(fFileSearchAborted));
end;

procedure TMedienBibliothek.fSetIgnoreLyrics(aValue: Boolean);
begin
    fIgnoreLyrics := aValue;
    if aValue then
        fIgnoreLyricsFlag := GAD_NOLYRICS
    else
        fIgnoreLyricsFlag := 0;
end;

{
    --------------------------------------------------------
    LoadFromIni
    SaveToIni
    Load/Save the settings into the IniFile
    --------------------------------------------------------
}
procedure TMedienBibliothek.LoadFromIni(ini: TMemIniFile);
var tmpcharcode, dircount, i: integer;
    tmp: UnicodeString;
    so, sd: Integer;
begin
        //BetaDontUseThreadedUpdate := Ini.ReadBool('Beta', 'DontUseThreadedUpdate', False);

        // temporary, maybe add an option later (or remove it completely, so use it always)
        UseNewFileScanMethod := ini.ReadBool('MedienBib', 'UseNewFileScanMethod', True);

        NempSortArray[1] := TAudioFileStringIndex(Ini.ReadInteger('MedienBib', 'Vorauswahl1', integer(siArtist)));
        NempSortArray[2] := TAudioFileStringIndex(Ini.ReadInteger('MedienBib', 'Vorauswahl2', integer(siAlbum)));

        if (NempSortArray[1] > siFileAge) OR (NempSortArray[2] > siFileAge) or
           (NempSortArray[1] < siArtist) OR (NempSortArray[2] < siArtist)then
        begin
          NempSortArray[1] := siArtist;
          NempSortArray[2] := siAlbum;
        end;

        AlwaysSortAnzeigeList := ini.ReadBool('MedienBib', 'AlwaysSortAnzeigeList', False);
        limitMarkerToCurrentFiles := ini.ReadBool('MedienBib', 'limitMarkerToCurrentFiles', True);
        SkipSortOnLargeLists  := ini.ReadBool('MedienBib', 'SkipSortOnLargeLists', True);
        AutoScanPlaylistFilesOnView := ini.ReadBool('MedienBib', 'AutoScanPlaylistFilesOnView', True);
        ShowHintsInMedialist := ini.ReadBool('Medienbib', 'ShowHintsInMedialist', True);

        for i := SORT_MAX downto 0 do
        begin
            so := Ini.ReadInteger('MedienBib', 'Sortorder' + IntToStr(i), CON_PFAD);
            self.AddSorter(so, False);
            sd := Ini.ReadInteger('MedienBib', 'SortMode' + IntToStr(i), Integer(sd_Ascending));
            if sd = Integer(sd_Ascending) then
                SortParams[i].Direction := sd_Ascending
            else
                SortParams[i].Direction := sd_Descending;
        end;

        TCoverArtSearcher.UseDir         := ini.ReadBool('MedienBib','CoverSearchInDir', True);
        TCoverArtSearcher.UseParentDir   := ini.ReadBool('MedienBib','CoverSearchInParentDir', True);
        TCoverArtSearcher.UseSubDir      := ini.ReadBool('MedienBib','CoverSearchInSubDir', True);
        TCoverArtSearcher.UseSisterDir   := ini.ReadBool('MedienBib', 'CoverSearchInSisterDir', True);
        TCoverArtSearcher.SubDirName     := ini.ReadString('MedienBib', 'CoverSearchSubDirName', 'cover');
        TCoverArtSearcher.SisterDirName  := ini.ReadString('MedienBib', 'CoverSearchSisterDirName', 'cover');
        TCoverArtSearcher.CoverSizeIndex := ini.ReadInteger('MedienBib', 'CoverSize', 1);
        TCoverArtSearcher.InitCoverArtCache(Savepath, TCoverArtSearcher.CoverSizeIndex);

        CoverSearchLastFM        := ini.ReadBool('MedienBib', 'CoverSearchLastFM', False);

        HideNACover := ini.ReadBool('MedienBib', 'HideNACover', False);
        MissingCoverMode := ini.ReadInteger('MedienBib', 'MissingCoverMode', 1);
        if (MissingCoverMode < 0) OR (MissingCoverMode > 2) then
            MissingCoverMode := 1;

        IgnoreLyrics := ini.ReadBool('MedienBib', 'IgnoreLyrics', False);

        BrowseMode     := Ini.ReadInteger('MedienBib', 'BrowseMode', 1);
        if (BrowseMode < 0) OR (BrowseMode > 2) then
          BrowseMode := 1;
        CoverSortOrder := Ini.ReadInteger('MedienBib', 'CoverSortOrder', 8);
        if (CoverSortOrder < 1) OR (CoverSortOrder > 9) then
          CoverSortorder := 1;

        IncludeAll := ini.ReadBool('MedienBib', 'other', True);
        IncludeFilter := Ini.ReadString('MedienBib', 'includefilter', '*.mp3;*.mp2;*.mp1;*.ogg;*.wav;*.wma;*.ape;*.flac');
        AutoLoadMediaList := ini.ReadBool('MedienBib', 'autoload', True);
        AutoSaveMediaList := ini.ReadBool('MedienBib', 'autosave', AutoLoadMediaList);

        tmpcharcode := ini.ReadInteger('MedienBib', 'CharSetGreek', 0);
        if (tmpcharcode < 0) or (tmpcharcode > 1) then tmpcharcode := 0;
        NempCharCodeOptions.Greek := GreekEncodings[tmpcharcode];

        tmpcharcode := ini.ReadInteger('MedienBib', 'CharSetCyrillic', 0);
        if (tmpcharcode < 0) or (tmpcharcode > 2) then tmpcharcode := 0;
        NempCharCodeOptions.Cyrillic := CyrillicEncodings[tmpcharcode];

        tmpcharcode := ini.ReadInteger('MedienBib', 'CharSetHebrew', 0);
        if (tmpcharcode < 0) or (tmpcharcode > 2) then tmpcharcode := 0;
        NempCharCodeOptions.Hebrew := HebrewEncodings[tmpcharcode];

        tmpcharcode := ini.ReadInteger('MedienBib', 'CharSetArabic', 0);
        if (tmpcharcode < 0) or (tmpcharcode > 2) then tmpcharcode := 0;
        NempCharCodeOptions.Arabic := ArabicEncodings[tmpcharcode];

        tmpcharcode := ini.ReadInteger('MedienBib', 'CharSetThai', 0);
        if (tmpcharcode < 0) or (tmpcharcode > 0) then tmpcharcode := 0;
        NempCharCodeOptions.Thai := ThaiEncodings[tmpcharcode];

        tmpcharcode := ini.ReadInteger('MedienBib', 'CharSetKorean', 0);
        if (tmpcharcode < 0) or (tmpcharcode > 0) then tmpcharcode := 0;
        NempCharCodeOptions.Korean := KoreanEncodings[tmpcharcode];

        tmpcharcode := ini.ReadInteger('MedienBib', 'CharSetChinese', 0);
        if (tmpcharcode < 0) or (tmpcharcode > 1) then tmpcharcode := 0;
        NempCharCodeOptions.Chinese := ChineseEncodings[tmpcharcode];

        tmpcharcode := ini.ReadInteger('MedienBib', 'CharSetJapanese', 0);
        if (tmpcharcode < 0) or (tmpcharcode > 0) then tmpcharcode := 0;
        NempCharCodeOptions.Japanese := JapaneseEncodings[tmpcharcode];

        NempCharCodeOptions.AutoDetectCodePage := ini.ReadBool('MedienBib', 'AutoDetectCharCode', True);

        InitialDialogFolder := Ini.ReadString('MedienBib', 'InitialDialogFolder', '');

        AutoScanDirs := Ini.ReadBool('MedienBib', 'AutoScanDirs', True);
        AskForAutoAddNewDirs  := Ini.ReadBool('MedienBib', 'AskForAutoAddNewDirs', True);
        AutoAddNewDirs        := Ini.ReadBool('MedienBib', 'AutoAddNewDirs', True);
        AutoDeleteFiles         := Ini.ReadBool('MedienBib', 'AutoDeleteFiles', False);
        AutoDeleteFilesShowInfo := Ini.ReadBool('MedienBib', 'AutoDeleteFilesShowInfo', False);

        AutoResolveInconsistencies          := Ini.ReadBool('MedienBib', 'AutoResolveInconsistencies'      , True);
        AskForAutoResolveInconsistencies    := Ini.ReadBool('MedienBib', 'AskForAutoResolveInconsistencies', True);
        ShowAutoResolveInconsistenciesHints := Ini.ReadBool('MedienBib', 'ShowAutoResolveInconsistenciesHints', True);

        AskForAutoResolveInconsistenciesRules := Ini.ReadBool('MedienBib', 'AskForAutoResolveInconsistenciesRules', True);
        AutoResolveInconsistenciesRules       := Ini.ReadBool('MedienBib', 'AutoResolveInconsistenciesRules'      , True);


        dircount := Ini.ReadInteger('MedienBib', 'dircount', 0);
        for i := 1 to dircount do
        begin
            tmp := Ini.ReadString('MedienBib', 'ScanDir' + IntToStr(i), '');
            if trim(tmp) <> '' then
            begin
                AutoScanDirList.Add(IncludeTrailingPathDelimiter(tmp));
                AutoScanToDoList.Add(IncludeTrailingPathDelimiter(tmp));
            end;
        end;

        AutoActivateWebServer := Ini.ReadBool('MedienBib', 'AutoActivateWebServer', False);

        if (ParamCount >= 1) and (ParamStr(1) = '/safemode') then
            NewCoverFlow.Mode := cm_Classic
        else
            NewCoverFlow.Mode := TCoverFlowMode(ini.ReadInteger('MedienBib', 'CoverFlowMode', Integer(cm_OpenGL))); // cm_OpenGL; //cm_Classic; //cm_OpenGL; //

        CurrentArtist := Ini.ReadString('MedienBib','SelectedArtist', BROWSE_ALL);
        CurrentAlbum := Ini.ReadString('MedienBib','SelectedAlbum', BROWSE_ALL);
        NewCoverFlow.CurrentCoverID := Ini.ReadString('MedienBib','SelectedCoverID', 'all');
        NewCoverFlow.CurrentItem    := ini.ReadInteger('MedienBib', 'SelectedCoverIDX', 0);

        // LYR_NONE, LYR_LYRICWIKI, LYR_CHARTLYRICS
        LyricPriorities[LYR_NONE]        := 100;
        LyricPriorities[LYR_LYRICWIKI]   := Ini.ReadInteger('MedienBib', 'PriorityLyricWiki'  , 1);
        LyricPriorities[LYR_CHARTLYRICS] := Ini.ReadInteger('MedienBib', 'PriorityChartLyrics', 2);

        BibSearcher.LoadFromIni(ini);
        TagCloud.LoadFromIni(ini);
end;
procedure TMedienBibliothek.WriteToIni(ini: TMemIniFile);
var i: Integer;
begin
        //Ini.WriteBool('Beta', 'DontUseThreadedUpdate', BetaDontUseThreadedUpdate);

        Ini.WriteInteger('MedienBib', 'Vorauswahl1', integer(NempSortArray[1]));
        Ini.WriteInteger('MedienBib', 'Vorauswahl2', integer(NempSortArray[2]));
        ini.WriteBool('MedienBib', 'AlwaysSortAnzeigeList', AlwaysSortAnzeigeList);
        ini.WriteBool('MedienBib', 'limitMarkerToCurrentFiles', limitMarkerToCurrentFiles);

        ini.WriteBool('MedienBib', 'SkipSortOnLargeLists', SkipSortOnLargeLists);

        ini.WriteBool('MedienBib', 'AutoScanPlaylistFilesOnView', AutoScanPlaylistFilesOnView);
        ini.WriteBool('Medienbib', 'ShowHintsInMedialist', ShowHintsInMedialist);

        for i := SORT_MAX downto 0 do
        begin
            Ini.WriteInteger('MedienBib', 'Sortorder' + IntToStr(i), SortParams[i].Tag);
            Ini.WriteInteger('MedienBib', 'SortMode' + IntToStr(i), Integer(SortParams[i].Direction));
        end;

        ini.Writebool('MedienBib','CoverSearchInDir', TCoverArtSearcher.UseDir);
        ini.Writebool('MedienBib','CoverSearchInParentDir', TCoverArtSearcher.UseParentDir);
        ini.Writebool('MedienBib','CoverSearchInSubDir', TCoverArtSearcher.UseSubDir);
        ini.Writebool('MedienBib', 'CoverSearchInSisterDir', TCoverArtSearcher.UseSisterDir);
        ini.WriteString('MedienBib', 'CoverSearchSubDirName', TCoverArtSearcher.SubDirName);
        ini.WriteString('MedienBib', 'CoverSearchSisterDirName', TCoverArtSearcher.SisterDirName);
        ini.WriteInteger('MedienBib', 'CoverSize', TCoverArtSearcher.CoverSizeIndex);

        ini.WriteBool('MedienBib', 'CoverSearchLastFM', CoverSearchLastFM);
        ini.WriteBool('MedienBib', 'HideNACover', HideNACover);
        ini.WriteInteger('MedienBib', 'MissingCoverMode', MissingCoverMode);

        ini.WriteBool('MedienBib', 'IgnoreLyrics', IgnoreLyrics);

        ini.WriteBool('MedienBib', 'other', IncludeAll);
        ini.WriteString('MedienBib', 'includefilter', IncludeFilter);
        ini.WriteBool('MedienBib', 'autoload', AutoLoadMediaList);
        ini.WriteBool('MedienBib', 'autosave', AutoSaveMediaList);

        ini.WriteInteger('MedienBib', 'CharSetGreek', NempCharCodeOptions.Greek.Index);
        ini.WriteInteger('MedienBib', 'CharSetCyrillic', NempCharCodeOptions.Cyrillic.Index);
        ini.WriteInteger('MedienBib', 'CharSetHebrew', NempCharCodeOptions.Hebrew.Index);
        ini.WriteInteger('MedienBib', 'CharSetArabic', NempCharCodeOptions.Arabic.Index);
        ini.WriteInteger('MedienBib', 'CharSetThai', NempCharCodeOptions.Thai.Index);
        ini.WriteInteger('MedienBib', 'CharSetKorean', NempCharCodeOptions.Korean.Index);
        ini.WriteInteger('MedienBib', 'CharSetChinese', NempCharCodeOptions.Chinese.Index);
        ini.WriteInteger('MedienBib', 'CharSetJapanese', NempCharCodeOptions.Japanese.Index);
        ini.WriteBool('MedienBib', 'AutoDetectCharCode', NempCharCodeOptions.AutoDetectCodePage);

        Ini.WriteString('MedienBib', 'InitialDialogFolder', InitialDialogFolder);
        Ini.WriteBool('MedienBib', 'AutoScanDirs', AutoScanDirs);
        Ini.WriteBool('MedienBib', 'AutoDeleteFiles', AutoDeleteFiles);
        Ini.WriteBool('MedienBib', 'AutoDeleteFilesShowInfo', AutoDeleteFilesShowInfo);
        Ini.WriteInteger('MedienBib', 'dircount', AutoScanDirList.Count);
        Ini.WriteBool('MedienBib', 'AskForAutoAddNewDirs', AskForAutoAddNewDirs);
        Ini.WriteBool('MedienBib', 'AutoAddNewDirs', AutoAddNewDirs);
        Ini.WriteBool('MedienBib', 'AutoActivateWebServer', AutoActivateWebServer);

        Ini.WriteBool('MedienBib', 'ShowAutoResolveInconsistenciesHints', ShowAutoResolveInconsistenciesHints);
        Ini.WriteBool('MedienBib', 'AskForAutoResolveInconsistencies', AskForAutoResolveInconsistencies);
        Ini.WriteBool('MedienBib', 'AutoResolveInconsistencies'      , AutoResolveInconsistencies);
        Ini.WriteBool('MedienBib', 'AskForAutoResolveInconsistenciesRules' , AskForAutoResolveInconsistenciesRules);
        Ini.WriteBool('MedienBib', 'AutoResolveInconsistenciesRules'       , AutoResolveInconsistenciesRules);

        ini.WriteInteger('MedienBib', 'BrowseMode', fBrowseMode);
        ini.WriteInteger('MedienBib', 'CoverSortOrder', fCoverSortOrder);

        for i := 0 to AutoScanDirList.Count -1  do
            Ini.WriteString('MedienBib', 'ScanDir' + IntToStr(i+1), AutoScanDirList[i]);

        Ini.WriteString('MedienBib','SelectedArtist', CurrentArtist);
        Ini.WriteString('MedienBib','SelectedAlbum', CurrentAlbum);
        Ini.WriteString('MedienBib','SelectedCoverID', NewCoverFlow.CurrentCoverID);
        Ini.WriteInteger('MedienBib', 'SelectedCoverIDX', NewCoverFlow.CurrentItem);

        Ini.WriteInteger('MedienBib', 'CoverFlowMode', Integer(NewCoverFlow.Mode));

        // LYR_NONE, LYR_LYRICWIKI, LYR_CHARTLYRICS
        Ini.WriteInteger('MedienBib', 'PriorityLyricWiki'  , LyricPriorities[LYR_LYRICWIKI]   );
        Ini.WriteInteger('MedienBib', 'PriorityChartLyrics', LyricPriorities[LYR_CHARTLYRICS] );

        BibSearcher.SaveToIni(Ini);
        TagCloud.SaveToIni(Ini);

        Ini.WriteBool('MedienBib', 'UseNewFileScanMethod', UseNewFileScanMethod);
end;


procedure TMedienBibliothek.ScanNewFilesAndUpdateBib;
var Dummy: Cardinal;
    i: Integer;
begin
    if Not FileSearchAborted then
    begin
        StatusBibUpdate := 1;
        // actually start scanning the files and merge them into the library afterwards
        fHND_ScanFilesAndUpdateThread  := BeginThread(Nil, 0, @fScanNewFilesAndUpdateBib, Self, 0, Dummy);
    end else
    begin
        // the search for new files has beem cancelled by the user.
        // Discard files in the UpdateList and cleanUP Progress-GUI
        for i := 0 to UpdateList.Count - 1 do
            UpdateList[i].Free;
        UpdateList.Clear;
         
        // we are in the main VCL Thread here.
        // however, use the same methods to finish the jobs as in the threaded methods
        SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                              Integer(PChar(_(  MediaLibrary_SearchingNewFiles_Aborted  )) ));
        SendMessage(MainWindowHandle, WM_MedienBib, MB_UnBlock, 0);

        // current //job// is done, set status to 0
        SendMessage(MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
        // check for the next job
        SendMessage(MainWindowHandle, WM_MedienBib, MB_CheckForStartJobs, 0);       
    end;
end;

procedure fScanNewFilesAndUpdateBib(MB: TMedienbibliothek);
begin
    if (MB.UpdateList.Count > 0) or (MB.PlaylistUpdateList.Count > 0) then
    begin
        // new part here: Scan the files first
        MB.UpdateFortsetzen := True;
        MB.fScanNewFiles;

        // Merge Files into the Library
        // Status is set properly in PrepareNewFilesUpdate
        MB.PrepareNewFilesUpdate;
        MB.SwapLists;
        MB.CleanUpTmpLists;
        SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                            Integer(PChar(_(MediaLibrary_SearchingNewFilesComplete ) )));
        //if MB.ChangeAfterUpdate then
        MB.Changed := True;
    end else
    begin
        SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                          Integer(PChar(_(MediaLibrary_SearchingNewFiles_NothingFound )) ));
        SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UnBlock, 0);
    end;

    // current //job// is done, set status to 0
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
    // check for the next job
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_CheckForStartJobs, 0);
    try
        CloseHandle(MB.fHND_ScanFilesAndUpdateThread);
    except
    end;
end;

procedure TMedienBibliothek.fScanNewFiles;
var i, freq, ges: Integer;
    AudioFile: TAudioFile;
    ct, nt: Cardinal;
    ScanList: TAudioFileList;
begin

  SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockUpdateStart, 0); // Or better MB_BlockWriteAccess? - No, it should be ok so.
  SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNormal));
  
  SendMessage(MainWindowHandle, WM_MedienBib, MB_StartLongerProcess, Integer(pa_ScanNewFiles));

  // release the Factory (but this should not happen here, as the Factory should have been NILed by the previous thread)
  if WICImagingFactory_ScanThread <> Nil then
  begin
      if WICImagingFactory_ScanThread._Release = 0 then
          Pointer(WICImagingFactory_ScanThread) := Nil;
  end;

  ges := UpdateList.Count;
  freq := Round(UpdateList.Count / 100) + 1;
  ct := GetTickCount;

  ScanList := TAudioFileList.Create(False);
  try
      // Transfer the items from the UpdateList into a temporary new List
      ScanList.Capacity := UpdateList.Count;
      for i := 0 to UpdateList.Count - 1 do
          ScanList.Add(UpdateList[i]);
      // Clear the original UpdateList
      UpdateList.Clear;

      ChangeAfterUpdate := True;
      for i := 0 to ScanList.Count - 1 do
      begin
          if Not UpdateFortsetzen then
          begin
              // Free the remaining AudioFiles in the ScanList, and
              // don't add them to the UpdateList, which is processed after this method
              ScanList[i].Free;
          end else
          begin
              AudioFile := ScanList[i];
              if FileExists(AudioFile.Pfad) then
              begin
                  AudioFile.FileIsPresent:=True;
                  AudioFile.GetAudioData(AudioFile.Pfad, GAD_Rating or IgnoreLyricsFlag);
                  CoverArtSearcher.InitCover(AudioFile, tm_Thread, INIT_COVER_DEFAULT);
              end
              else
              begin
                  // should npt happen here ...
                  AudioFile.FileIsPresent:=False;
              end;
              // Add the File to the UpdateList, which is merged into the MediaLibrary later.
              UpdateList.Add(AudioFile);

              nt := GetTickCount;
              if (i mod freq = 0) or (nt > ct + 500) or (nt < ct) then
              begin
                  ct := nt;

                  SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressCurrentFileOrDirUpdate,
                                  Integer(PWideChar(Format(_(MediaLibrary_ScanningFilesInDir),
                                                        [ AudioFile.Ordner ]))));

                  SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressScanningNewFiles,
                                  Integer(PWideChar(Format(_(MediaLibrary_ScanningFilesCount),
                                                        [ i, ges ]))));

                  SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, Round(i/ges * 100));
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessSuccessCount, i+1);
                  // No counting of non-existing files here
                  // SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessFailCount, DeadFiles.Count);
              end;
          end;
      end;

      // release the Factory now, scanning is complete and the the thread will terminate soon
      if WICImagingFactory_ScanThread <> Nil then
      begin
          if WICImagingFactory_ScanThread._Release = 0 then
              Pointer(WICImagingFactory_ScanThread) := Nil;
      end;

      // progress complete
      SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, 100);

  finally
      ScanList.Free;
  end;
end;

{
    --------------------------------------------------------
    NewFilesUpdateBib
    - Public method for merging new files into the library
      The new files are stored in UpdateList and came from
       - a *.gmp-File (happens when starting Nemp)
       - a search for mp3-Files done with SearchUtils

    Note: This Method is called after loading a Library-File,
          and after a FileSearch
          It should NOT check for status = 0, but it MUST set it
          to 2 immediatly
          Check =/<> 0 MUST be done outside!
    --------------------------------------------------------
}
procedure TMedienBibliothek.NewFilesUpdateBib(NewBib: Boolean = False);
var Dummy: Cardinal;
begin
  ChangeAfterUpdate := Not NewBib;
  if NewBib then Changed := False;
  // Some people reported strange errors on startup, which possibly
  // be caused by this thread. So in this case call the thread method
  // directly.
  StatusBibUpdate := 2;
  //if BetaDontUseThreadedUpdate then
  //begin
  //    fNewFilesUpdate(self);
  //    fHND_UpdateThread := 0;
  //end
  //else
      fHND_UpdateThread := (BeginThread(Nil, 0, @fNewFilesUpdate, Self, 0, Dummy));
end;
{
    --------------------------------------------------------
    fNewFilesUpdate
    - runs in secondary thread and calls the private Library-Methods
      Note: These methods will send several Messages to Mainform to
      block Read/Write-Access to the library when its needed.
    --------------------------------------------------------
}
procedure fNewFilesUpdate(MB: TMedienbibliothek);
begin
  if (MB.UpdateList.Count > 0) or (MB.PlaylistUpdateList.Count > 0) then
  begin                        // status: Temporary comments, as I found a concept-bug here ;-)
    MB.PrepareNewFilesUpdate;  // status: ok (no StatusChange needed)
    MB.SwapLists;              // status: ok (StatusChange via SendMessage)
    MB.CleanUpTmpLists;        // status: ok (No StatusChange allowed)

    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                        Integer(PChar(_(MediaLibrary_SearchingNewFilesComplete ) )));

    if MB.ChangeAfterUpdate then
        MB.Changed := True;
  end else
  begin
      SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                        Integer(PChar(_(MediaLibrary_SearchingNewFiles_NothingFound )) ));

      SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UnBlock, 0);
  end;

  // current //job// is done, set status to 0
  SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
  // check for the next job
  SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_CheckForStartJobs, 0);

  try
      CloseHandle(MB.fHND_UpdateThread);
  except
  end;
end;
{
    --------------------------------------------------------
    PrepareNewFilesUpdate
    - Merge UpdateList with MainList into tmp-List
      VCL MUST NOT write on the library,
      e.g. no Sorting
           no ID3-Tag-Editing
      Duration of this Operation: a few seconds
    --------------------------------------------------------
}
procedure TMedienBibliothek.PrepareNewFilesUpdate;
var i, d: Integer;
    aAudioFile: TAudioFile;
begin
  SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockWriteAccess, 0);

  SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressShowHint, Integer(PChar(MediaLibrary_Preparing)));

  UpdateList.Sort(Sort_Pfad_asc);

  Merge(UpdateList, Mp3ListePfadSort, tmpMp3ListePfadSort, SO_Pfad, NempSortArray);
  PlaylistUpdateList.Sort(PlaylistSort_Pfad);
  MergePlaylists(PlaylistUpdateList, AllPlaylistsPfadSort, tmpAllPlaylistsPfadSort);

  if ChangeAfterUpdate then
  begin
      // i.e. new files, not from a *.gmp-File
      // Collect information of used Drives
      // AddUsedDrivesInformation(UpdateList, PlaylistUpdateList);
      EnterCriticalSection(CSAccessDriveList);
      fDriveManager.AddDrivesFromAudioFiles(UpdateList);
      fDriveManager.AddDrivesFromPlaylistFiles(PlaylistUpdateList);
      LeaveCriticalSection(CSAccessDriveList);
  end;

  // Build proper Browse-Lists
  case BrowseMode of
      0: begin
          // Classic Browsing: Artist-Album (or whatever the user wanted)
          UpdateList.Sort(Sort_String1String2Titel_asc);

          if fBrowseListsNeedUpdate then
          begin
              // We need Block-READ-access in this case here!
              SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockReadAccess, 0);
              // Set the status of the library to Readaccessblocked
              SendMessage(MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_ReadAccessBlocked);
          end;

          if fBrowseListsNeedUpdate then
              Mp3ListeArtistSort.Sort(Sort_String1String2Titel_asc);
              //(Sortieren_String1String2Titel_asc);
          Merge(UpdateList, Mp3ListeArtistSort, tmpMp3ListeArtistSort, SO_ArtistAlbum, NempSortArray);

          if fBrowseListsNeedUpdate then
              Mp3ListeAlbenSort.Sort(Sort_String2String1Titel_asc);
              //(Sortieren_String2String1Titel_asc);
          UpdateList.Sort(Sort_String2String1Titel_asc);
          //(Sortieren_String2String1Titel_asc);
          Merge(UpdateList, Mp3ListeAlbenSort, tmpMp3ListeAlbenSort, SO_AlbumArtist, NempSortArray);

          fBrowseListsNeedUpdate := False;
      end;
      1: begin
          // Coverflow
          UpdateList.Sort(Sort_CoverID);
          //(Sortieren_CoverID);

          if fBrowseListsNeedUpdate then
          begin
              // We need Block-READ-access in this case here!
              SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockReadAccess, 0);
              // Set the status of the library to Readaccessblocked
              SendMessage(MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_ReadAccessBlocked);
          end;

          if fBrowseListsNeedUpdate then
          begin
              Mp3ListeArtistSort.Sort(Sort_CoverID);
              //(Sortieren_CoverID);
              Mp3ListeAlbenSort.Sort(Sort_CoverID);
              //(Sortieren_CoverID);
          end;

          Merge(UpdateList, Mp3ListeArtistSort, tmpMp3ListeArtistSort, SO_Cover, NempSortArray);
          Merge(UpdateList, Mp3ListeAlbenSort, tmpMp3ListeAlbenSort, SO_Cover, NempSortArray);
      end;
      2: begin
          // TagCloud: Just put all files into the tmp-Lists
          // we do not need them really, but at least the file therein should be the same as in the PfadSortList
          tmpMp3ListeArtistSort.Clear;
          for i := 0 to Mp3ListeArtistSort.Count - 1 do
              tmpMp3ListeArtistSort.Add(Mp3ListeArtistSort[i]);
          tmpMp3ListeAlbenSort.Clear;
          for i := 0 to Mp3ListeAlbenSort.Count - 1 do
              tmpMp3ListeAlbenSort.Add(Mp3ListeAlbenSort[i]);
          for i := 0 to UpdateList.Count - 1 do
          begin
              tmpMp3ListeArtistSort.Add(UpdateList[i]);
              tmpMp3ListeAlbenSort.Add(UpdateList[i]);
          end;
      end;
  end;


  // Check for Duplicates
  // Note: This test should be always negative. If not, something in the system went wrong. :(
  //       Probably the Sort and Binary-Search methods do not match then.
  for i := 0 to tmpMp3ListePfadSort.Count-2 do
  begin
    if tmpMp3ListePfadSort[i].Pfad = tmpMp3ListePfadSort[i+1].Pfad then
    begin
      // Oops. Send Warning to MainWindow
      SendMessage(MainWindowHandle, WM_MedienBib, MB_DuplicateWarning, Integer(pWideChar(tmpMp3ListePfadSort[i].Pfad)));
      ChangeAfterUpdate := True; // We need to save the changed library after the cleanup

      AnzeigeListe.Clear;
      AnzeigeListIsCurrentlySorted := False;
      SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList, 0);
      // Delete Duplicates
      for d := tmpMp3ListePfadSort.Count-1 downto 1 do
      begin
        if tmpMp3ListePfadSort[d-1].Pfad = tmpMp3ListePfadSort[d].Pfad then
        begin
          aAudioFile := tmpMp3ListePfadSort[d];
          tmpMp3ListePfadSort.Extract(aAudioFile);
          tmpMp3ListeArtistSort.Extract(aAudioFile);
          tmpMp3ListeAlbenSort.Extract(aAudioFile);

          BibSearcher.RemoveAudioFileFromLists(aAudioFile);
          FreeAndNil(aAudioFile);
        end;
      end;
      // break testing-loop. Duplicates has been deleted.
      break;
    end;
  end;


  // Prepare BrowseLists
  case BrowseMode of
      0: begin
          InitAlbenlist(tmpMp3ListeAlbenSort, tmpAlleAlben);
          Generateartistlist(tmpMp3ListeArtistSort, tmpAlleArtists);
      end;
      1: begin
          GenerateCoverList(tmpMp3ListeArtistSort, tmpCoverList);
      end;
      2: begin
          // nothing to do. TagCloud will be rebuild in "RefillBrowseTrees"
      end;
  end;

end;


(*
{
    --------------------------------------------------------
    AddUsedDrivesInformation
    - Check and Update UsedDrivesList
    --------------------------------------------------------
}
procedure TMedienBibliothek.AddUsedDrivesInformation(aList: TObjectlist; aPlaylistList: TObjectList);
var ActualDrive: WideChar;
    i: Integer;
    NewDrive: TDrive;
begin
    EnterCriticalSection(CSAccessDriveList);
    ActualDrive := '-';
    for i := 0 to aList.Count - 1 do
    begin
        if T---AudioFile(aList[i]).Pfad[1] <> ActualDrive then
        begin
            ActualDrive := T--AudioFile(aList[i]).Pfad[1];

            if ActualDrive <> '\' then
            begin
                if not Assigned(GetDriveFromListByChar(fUsedDrives, Char(ActualDrive))) then
                begin
                    NewDrive := TDrive.Create;
                    NewDrive.GetInfo(ActualDrive + ':\');
                    fUsedDrives.Add(NewDrive);
                end;
            end;
        end;
    end;

    ActualDrive := '-';
    for i := 0 to aPlaylistList.Count - 1 do
    begin
        if TJustaString(aPlaylistList[i]).DataString[1] <> ActualDrive then
        begin
            ActualDrive := TJustaString(aPlaylistList[i]).DataString[1];
            if ActualDrive <> '\' then
            begin
                if not Assigned(GetDriveFromListByChar(fUsedDrives, Char(ActualDrive))) then
                begin
                    NewDrive := TDrive.Create;
                    NewDrive.GetInfo(ActualDrive + ':\');
                    fUsedDrives.Add(NewDrive);
                end;
            end;
        end;
    end;
    LeaveCriticalSection(CSAccessDriveList);
end;
*)
{
    --------------------------------------------------------
    SwapLists
    - Swap temporary lists with real ones.
      VCL MUST NOT read on the library
    Duration of this Operation: a few milli-seconds, almost nothing
    --------------------------------------------------------
}
procedure TMedienBibliothek.SwapLists;
var swaplist: TAudioFileList;
    swaplist2: TObjectList;
    swapstlist: TStringList;
begin
  EnterCriticalSection(CSUpdate);

  SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockReadAccess, 0);
  // Set the status of the library to Readaccessblocked
  SendMessage(MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_ReadAccessBlocked);
  /// StatusBibUpdate := BIB_Status_ReadAccessBlocked;

  swaplist := Mp3ListePfadSort;
  Mp3ListePfadSort := tmpMp3ListePfadSort;
  BibSearcher.MainList := Mp3ListePfadSort;
  tmpMp3ListePfadSort := swaplist;

  swaplist := Mp3ListeArtistSort;
  Mp3ListeArtistSort := tmpMp3ListeArtistSort;
  tmpMp3ListeArtistSort := swaplist;

  swaplist := Mp3ListeAlbenSort;
  Mp3ListeAlbenSort := tmpMp3ListeAlbenSort;
  tmpMp3ListeAlbenSort := swaplist;

  swaplist2 := AlleArtists;
  AlleArtists := tmpAlleArtists;
  tmpAlleArtists := swaplist2;

  swaplist2 := Coverlist;
  Coverlist := tmpCoverlist;
  tmpCoverlist := swaplist2;

  swapstlist := AlleAlben;
  AlleAlben := tmpAlleAlben;
  tmpAlleAlben := swapstlist;

  swapList2 := AllPlaylistsPfadSort;
  AllPlaylistsPfadSort := tmpAllPlaylistsPfadSort;
  tmpAllPlaylistsPfadSort := swapList2;
  InitPlayListsList;

  BibSearcher.BuildTotalSearchStrings(Mp3ListePfadSort);

  LeaveCriticalSection(CSUpdate);

// Send Refill-Message
  SendMessage(MainWindowHandle, WM_MedienBib, MB_RefillTrees, LParam(True));
end;
{
    --------------------------------------------------------
    CleanUpTmpLists
    - After Update, clear the temporary lists
      and give VCL full access to library again
    Duration: a few milli-seconds
    --------------------------------------------------------
}
procedure TMedienBibliothek.CleanUpTmpLists;
var i: Integer;
  aString: tJustAString;
begin
  // Die Objekte hierdrin werden noch alle gebraucht!
  tmpMp3ListeArtistSort.Clear;
  tmpMp3ListeAlbenSort.Clear;
  tmpMp3ListePfadSort.Clear;
  tmpAllPlaylistsPfadSort.Clear;
  tmpAlleAlben.Clear;
  // alte JustaStrings l�schen
  for i := 0 to tmpAlleArtists.Count - 1 do
  begin
    aString := tJustAString(tmpAlleArtists[i]);
    FreeAndNil(aString);
  end;
  tmpAlleArtists.Clear;
  Updatelist.Clear;
  PlaylistUpdateList.Clear;
  // Send UnBlock-Message
  SendMessage(MainWindowHandle, WM_MedienBib, MB_UnBlock, 0);
  /// StatusBibUpdate := 0;      // THIS IS DANGEROUS. DON NOT DO THIS HERE !!!
  {.$Message Warn 'Status darf im Thread nicht gesetzt werden'}
  {.$Message Warn 'Und auf 0 gar nicht, weil es hier evtl. noch weitergeht!!'}
end;

{
    --------------------------------------------------------
    DeleteFilesUpdateBib
    - Collect dead files (i.e. not existing files) and remove them
      from the library
    --------------------------------------------------------
}
Procedure TMedienBibliothek.DeleteFilesUpdateBib;
  var Dummy: Cardinal;
begin
  if StatusBibUpdate = 0 then
  begin
      UpdateFortsetzen := True;
      StatusBibUpdate := 1;
      fHND_DeleteFilesThread := BeginThread(Nil, 0, @fDeleteFilesUpdateUser, Self, 0, Dummy);
  end;
end;

Procedure TMedienBibliothek.DeleteFilesUpdateBibAutomatic;
  var Dummy: Cardinal;
begin
  if StatusBibUpdate = 0 then
  begin
      UpdateFortsetzen := True;
      StatusBibUpdate := 1;
      fHND_DeleteFilesThread := BeginThread(Nil, 0, @fDeleteFilesUpdateAutomatic, Self, 0, Dummy);
  end else
      // consider it done.
      SendMessage(MainWindowHandle, WM_MedienBib, MB_CheckForStartJobs, 0);
end;
{
    --------------------------------------------------------
    fDeleteFilesUpdate_USER||Automatic
    - runs in secondary thread and calls several private methods
    --------------------------------------------------------
}
Procedure fDeleteFilesUpdateUser(MB: TMedienbibliothek);
begin
    fDeleteFilesUpdateContainer(MB, true);
end;
Procedure fDeleteFilesUpdateAutomatic(MB: TMedienbibliothek);
begin
    fDeleteFilesUpdateContainer(MB, false);
end;

Procedure fDeleteFilesUpdateContainer(MB: TMedienbibliothek; askUser: Boolean);
var DeleteDataList: TObjectList;
    SummaryDeadFiles: TDeadFilesInfo;
begin
    // Status is = 1 here (see above)     // status: Temporary comments, as I found a concept-bug here ;-)
    MB.fCollectDeadFiles;                  // status: ok, no change needed
    // there ---^ check MB.fCurrentJob for a matching parameter


    if (MB.DeadFiles.Count + MB.DeadPlaylists.Count) > 0 then
    begin
        DeleteDataList := TObjectList.Create(True);
        try
            MB.fPrepareUserInputDeadFiles(DeleteDataList);
            if askUser then
            begin
                // let the user correct the list
                SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_ProgressShowHint, Integer(PChar(_(MediaLibrary_SearchingMissingFilesComplete_PrepareUserInput))));

                SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UserInputDeadFiles, lParam(DeleteDataList));
                MB.fReFillDeadFilesByDataList(DeleteDataList);
            end
            else
            begin
                // user can't change anything, fill the list
                MB.fReFillDeadFilesByDataList(DeleteDataList);
                // create a message containing a summary of the files to be deleted now (for logging, if wanted)
                MB.fGetDeadFilesSummary(DeleteDataList, SummaryDeadFiles);
                SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_InfoDeadFiles, lParam(@SummaryDeadFiles));
            end;
        finally
            DeleteDataList.Free;
        end;
    end;

    if (MB.DeadFiles.Count + MB.DeadPlaylists.Count) > 0 then
    begin
        MB.fPrepareDeleteFilesUpdate;          // status: ok, change via SendMessage
        // if (MB.DeadFiles.Count + MB.DeadPlaylists.Count) > 0 then
           MB.Changed := True;
        MB.SwapLists;                         // status: ok, change via SendMessage
        // Delete AudioFiles from "VCL-Lists"
        // This includes AnzeigeListe and the BibSearcher-Lists
        // MainForm will call CleanUpDeadFilesFromVCLLists
        SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_CheckAnzeigeList, 0);
        // Free deleted AudioFiles
        MB.fCleanUpDeadFiles;                  // status: ok, no change needed
        // Clear temporary lists
        MB.CleanUpTmpLists;                   // status: ok, no change allowed

        SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                        Integer(PChar(_(DeleteSelect_DeletingFilesComplete )) ));
    end else
    begin
        SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_CheckAnzeigeList, 0);
        SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UnBlock, 0);

        SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                        Integer(PChar(_(DeleteSelect_DeletingFilesAborted )) ));
    end;

    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free); // status: ok, thread finished
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_CheckForStartJobs, 0);

    try
        CloseHandle(MB.fHND_DeleteFilesThread);
    except
    end;
end;

{
    --------------------------------------------------------
    CollectDeadFiles
    - Block Update-Access to library.
      i.e. VCL MUST NOT start a searching for new files
    --------------------------------------------------------
}
Function TMedienBibliothek.fCollectDeadFiles: Boolean;
var i, ges, freq: Integer;
    nt, ct: Cardinal;
begin
      SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockUpdateStart, 0);
      SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNormal));
      SendMessage(MainWindowHandle, WM_MedienBib, MB_StartLongerProcess, Integer(pa_CleanUp));

      ges := Mp3ListePfadSort.Count + AllPlaylistsPfadSort.Count  + 1;
      freq := Round(ges / 100) + 1;
      ct := GetTickCount;
      for i := 0 to Mp3ListePfadSort.Count-1 do
      begin
          if Not FileExists(Mp3ListePfadSort[i].Pfad) then
            DeadFiles.Add(Mp3ListePfadSort[i]);

          nt := GetTickCount;
          if (i mod freq = 0) or (nt > ct + 500) or (nt < ct) then
          begin
                ct := nt;
                SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressSearchDead,
                      Integer(PChar( Mp3ListePfadSort[i].Ordner)) );

                SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, Round(i/ges * 100));
                // SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressSearchDead, Round(i/ges * 100));

                SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessSuccessCount, (i+1) - DeadFiles.Count);
                SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessFailCount, DeadFiles.Count);
          end;

          if not UpdateFortsetzen then break;
      end;

      for i := 0 to AllPlaylistsPfadSort.Count-1 do
      begin
          if Not FileExists(TJustaString(AllPlaylistsPfadSort[i]).DataString) then
            DeadPlaylists.Add(AllPlaylistsPfadSort[i] as TJustaString);

          nt := GetTickCount;
          if (i mod freq = 0) or (nt > ct + 500) or (nt < ct) then
          begin
              ct := nt;
              SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressSearchDead, Integer(PChar(MediaLibrary_SearchingMissingPlaylist)));
              SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, Round((Mp3ListePfadSort.Count+i)/ges * 100));

              SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessSuccessCount,
                                Mp3ListePfadSort.Count + i - DeadFiles.Count - DeadPlaylists.Count);
              SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessFailCount,
                                DeadFiles.Count + DeadPlaylists.Count);
          end;

          if not UpdateFortsetzen then break;
      end;
      result := True;

      SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressShowHint, Integer(PChar(MediaLibrary_SearchingMissingFilesComplete_AnalysingData)));
      SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, 100);
      SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNoProgress));
end;
{
    --------------------------------------------------------
    UserInputDeadFiles
    - Let the user select file that shoul be deleted (or not)
    - change DeadFiles acording to user input
    --------------------------------------------------------
}
procedure TMedienBibliothek.fPrepareUserInputDeadFiles(DeleteDataList: TObjectList);
var i: Integer;
    // LogicalDrives: TObjectList;
    currentDir: String;
    currentLogicalDrive, currentLibraryDrive: TDrive;
    currentDriveChar: Char;
    currentPC: String;
    newDeleteData, currentDeleteData: TDeleteData;

    function IsLocalDir(aFilename: String): Boolean;
    begin
        if length(aFilename) > 1 then
            result := aFilename[1] <> '\'
        else
            result := False;
    end;


    function ExtractPCNameFromPath(aDir: String): String;
    var posSlash: Integer;
    begin
        posSlash := posEx('\', aDir, 3);
        if posSlash >= 3 then
            result := Copy(aDir, 1, posSlash)
        else
            result := '';
    end;

    function RessourceCount(aPC: String): Integer;
    var j, c: Integer;
    begin
        c := 0;
        for j := 0 to mp3ListePfadSort.Count - 1 do
        begin
            if AnsiStartsText(aPC, Mp3ListePfadSort[j].Ordner) then
                inc(c);
        end;
        result := c;
    end;

    function GetMatchingDeleteDataObject(aDrive: String; isLocal: Boolean): TDeleteData;
    var i: Integer;
        fcurrentLogicalDrive, fcurrentLibraryDrive: TDrive;
    begin
        result := Nil;
        for i := 0 to DeleteDataList.Count - 1 do
        begin
            if TDeleteData(DeleteDataList[i]).DriveString = aDrive then
            begin
                result := TDeleteData(DeleteDataList[i]);
                break;
            end;
        end;

        if not assigned(result) then
        begin
            // create a new DeleteDataObject
            result := TDeleteData.Create;
            result.DriveString := aDrive;
            DeleteDataList.Add(result);
            if isLocal then
            begin
                fcurrentLogicalDrive := fDriveManager.GetPhysicalDriveByChar(aDrive[1]);
                                        // GetDriveFromListByChar(LogicalDrives, aDrive[1]);
                fcurrentLibraryDrive := fDriveManager.GetManagedDriveByChar(aDrive[1]);
                                        // GetDriveFromListByChar(fUsedDrives, aDrive[1]);
                if fcurrentLogicalDrive = NIL then
                begin
                    // complete Drive is NOT there
                    result.DoDelete       := False;
                    result.Hint           := dh_DriveMissing;

                    if assigned(fcurrentLibraryDrive) then
                        result.DriveType := fcurrentLibraryDrive.typ
                    else
                        result.DriveType := DriveTypeTexts[DRIVE_REMOTE];
                end else
                begin
                    // drive is there => just the file is not present
                    result.DoDelete    := True;
                    result.Hint        := dh_DivePresent;
                    result.DriveType   := fcurrentLibraryDrive.typ
                end;
            end else
            begin
                // assume that its missing, further check after this loop
                result.DoDelete    := False;
                result.Hint        := dh_NetworkMissing;
                result.DriveType   := DriveTypeTexts[DRIVE_REMOTE];
            end;
        end;
    end;

begin
    EnterCriticalSection(CSAccessDriveList);
    // prepare data - check whether the drive of the issing files exists etc.
    //LogicalDrives := TObjectList.Create;
    //try
    // fDriveManager.InitPhysicalDriveList;
    // GetLogicalDrives(LogicalDrives); // get connected logical drives

    currentDriveChar  := ' ';    // invalid drive letter
    currentPC         := 'XXX';  // invalid PC-Name
    newDeleteData     := Nil;

    for i := 0 to DeadFiles.Count - 1 do
    begin
        currentDir := DeadFiles[i].Ordner;
        if length(currentDir) > 0 then
        begin
            if IsLocalDir(currentDir) then
            begin
                // C:\, F:\, whatever - a LOCAL drive
                if currentDriveChar <> currentDir[1] then
                begin
                    // beginning of a ne drive - check for this drive
                    currentDriveChar := currentDir[1];
                    currentLogicalDrive := fDriveManager.GetPhysicalDriveByChar(currentDriveChar);
                                           // GetDriveFromListByChar(LogicalDrives, currentDriveChar);
                    currentLibraryDrive := fDriveManager.GetManagedDriveByChar(currentDriveChar);
                                           // GetDriveFromListByChar(fUsedDrives, currentDriveChar);
                    newDeleteData := TDeleteData.Create;
                    newDeleteData.DriveString := currentDriveChar; // at first only the letter + ':\';
                    if currentLogicalDrive = NIL then
                    begin
                        // complete logical Drive is NOT there
                        newDeleteData.DoDelete       := False;
                        newDeleteData.Hint           := dh_DriveMissing;

                        // use the drivetype from the library
                        if assigned(currentLibraryDrive) then
                            newDeleteData.DriveType := currentLibraryDrive.typ
                        else
                            // fallback to "remote" (but this should not happen)
                            newDeleteData.DriveType := DriveTypeTexts[DRIVE_REMOTE];
                    end else
                    begin
                        // drive is there => just the file is not present
                        newDeleteData.DoDelete       := True;
                        newDeleteData.Hint           := dh_DivePresent;
                        newDeleteData.DriveType      := currentLogicalDrive.Typ;
                    end;
                    DeleteDataList.Add(newDeleteData);
                end;
            end else
            begin
                // File on another pc in the network
                if not AnsiStartsText(currentPC, currentDir)  then
                begin
                    currentPC := ExtractPCNameFromPath(currentDir);
                    newDeleteData := TDeleteData.Create;
                    newDeleteData.DriveString := currentPC ;
                    // assume that its missing, further check after this loop
                    newDeleteData.DoDelete       := False;
                    newDeleteData.Hint           := dh_NetworkMissing;
                    newDeleteData.DriveType  := DriveTypeTexts[DRIVE_REMOTE];
                    DeleteDataList.Add(newDeleteData);
                end;
            end;
        end; // otherwise something is really wrong with the file. ;-)
        // Add file to the DeleteData-Objects FileList
        if assigned(newDeleteData) then
            newDeleteData.Files.Add(DeadFiles[i]);
    end;

    // The same for playlists, but re-use the existing DeleteDataList-Objects
    currentDeleteData := Nil;
    currentDriveChar  := ' ';    // invalid drive letter
    currentPC         := 'XXX';  // invalid PC-Name

    for i := 0 to DeadPlaylists.Count - 1 do
    begin
        currentDir := TJustAString(DeadPlaylists[i]).DataString;
        if length(currentDir) > 0 then
        begin
            if IsLocalDir(currentDir) then
            begin
                if currentDriveChar <> currentDir[1] then
                begin
                    // beginning of a new drive - Get a matching DeleteData-Object from the already existing list
                    // (or create a new one)
                    currentDriveChar := currentDir[1];
                    currentDeleteData := GetMatchingDeleteDataObject(currentDriveChar{ + ':\'}, True);
                end;
            end else
            begin
                // File on another pc in the network
                if not AnsiStartsText(currentPC, currentDir)  then
                begin
                    currentPC := ExtractPCNameFromPath(currentDir);
                    currentDeleteData := GetMatchingDeleteDataObject(currentPC, False);
                end;
            end;
        end;
        // Add file to the DeleteData-Objects Playlist-FileList
        if assigned(currentDeleteData) then
            currentDeleteData.PlaylistFiles.Add(DeadPlaylists[i]);
    end;

    // make the drivestrings a little bit nicer, add the name (from the library-drive)
    for i := 0 to DeleteDataList.Count-1 do
    begin
        currentDeleteData := TDeleteData(DeleteDataList[i]);
        if Length(currentDeleteData.DriveString) > 0 then
        begin
            currentLibraryDrive := fDriveManager.GetManagedDriveByChar(currentDeleteData.DriveString[1]);
                      //GetDriveFromListByChar(fUsedDrives, currentDeleteData.DriveString[1]);

            if assigned(currentLibraryDrive) then
                currentDeleteData.DriveString := currentDeleteData.DriveString
                  + ':\ (' + currentLibraryDrive.Name + ')';
        end;
    end;

    // Try to determine, whether network-ressources are online or not
    for i := 0 to DeleteDataList.Count - 1 do
    begin
        if TDeleteData(DeleteDatalist[i]).DriveString[1] = '\' then
        begin
            if RessourceCount(TDeleteData(DeleteDatalist[i]).DriveString) >
               TDeleteData(DeleteDatalist[i]).Files.Count then
            begin
                // some files on this ressource can be found
                TDeleteData(DeleteDatalist[i]).DoDelete       := True;
                TDeleteData(DeleteDatalist[i]).Hint           := dh_NetworkPresent;
            end;
        end;
    end;
    //finally
    //    LogicalDrives.Free;
    //end;
    LeaveCriticalSection(CSAccessDriveList);
end;
{
    --------------------------------------------------------
    ReFillDeadFilesByDataList
    - Refill the DeadFiles-List according to which files
      the user wants to be deleted
    --------------------------------------------------------
}
procedure TMedienBibliothek.fReFillDeadFilesByDataList(DeleteDataList: TObjectList);
var i, f: Integer;
    currentData: TDeleteData;
begin
    DeadFiles.Clear;
    DeadPlaylists.Clear;

    for i := 0 to DeleteDataList.Count - 1 do
    begin
        currentData := TDeleteData(DeleteDataList[i]);
        if currentData.DoDelete then
        begin
            for f := 0 to currentData.Files.Count - 1 do
                DeadFiles.Add(currentData.Files[f]);
            for f := 0 to currentData.PlaylistFiles.Count - 1 do
                Deadplaylists.Add(currentData.PlaylistFiles[f]);
        end;
    end;
end;

procedure TMedienBibliothek.fGetDeadFilesSummary(DeleteDataList: TObjectList; var aSummary: TDeadFilesInfo);
var i: Integer;
    currentData: TDeleteData;
begin
    aSummary.MissingDrives := 0;
    aSummary.ExistingDrives := 0;
    aSummary.MissingFilesOnMissingDrives := 0;
    aSummary.MissingFilesOnExistingDrives := 0;
    aSummary.MissingPlaylistsOnMissingDrives := 0 ;
    aSummary.MissingPlaylistsOnExistingDrives := 0;

    for i := 0 to DeleteDataList.Count - 1 do
    begin
        currentData := TDeleteData(DeleteDataList[i]);
        if currentData.DoDelete then
        begin
            aSummary.ExistingDrives := aSummary.ExistingDrives + 1;
            aSummary.MissingFilesOnExistingDrives := aSummary.MissingFilesOnExistingDrives + currentData.Files.Count;
            aSummary.MissingPlaylistsOnExistingDrives := aSummary.MissingPlaylistsOnExistingDrives + currentData.PlaylistFiles.Count;
        end else
        begin
            aSummary.MissingDrives := aSummary.MissingDrives  + 1;
            aSummary.MissingFilesOnMissingDrives := aSummary.MissingFilesOnMissingDrives + currentData.Files.Count;
            aSummary.MissingPlaylistsOnMissingDrives := aSummary.MissingPlaylistsOnMissingDrives + currentData.PlaylistFiles.Count;
        end;
    end;
end;
{
    --------------------------------------------------------
    PrepareDeleteFilesUpdate
    - Block Write-Access to library.
    - "AntiMerge" DeadFiles and Mainlist to tmp-List
    --------------------------------------------------------
}
procedure TMedienBibliothek.fPrepareDeleteFilesUpdate;
var i: Integer;
begin
  SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockWriteAccess, 0);
  SendMessage(MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_WriteAccessBlocked);

  SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressShowHint, Integer(PChar(DeleteSelect_DeletingFiles)));

  DeadFiles.Sort(Sort_Pfad_asc);
  //(Sortieren_Pfad_asc);
  AntiMerge(Mp3ListePfadSort, DeadFiles, tmpMp3ListePfadSort);

  AntiMergePlaylists(AllPlaylistsPfadSort, DeadPlaylists, tmpAllPlaylistsPfadSort);

  // Der Rest geht nicht mit AntiMerge. :(
  case BrowseMode of
      0: begin
          // Classic browse
          tmpMp3ListeArtistSort.Clear;
          for i := 0 to tmpMp3ListePfadSort.Count - 1 do
            tmpMp3ListeArtistSort.Add(tmpMp3ListePfadSort[i]);
          tmpMp3ListeArtistSort.Sort(Sort_String1String2Titel_asc);
          //Sort(Sortieren_String1String2Titel_asc);

          tmpMp3ListeAlbenSort.Clear;
          for i := 0 to tmpMp3ListePfadSort.Count - 1 do
            tmpMp3ListeAlbenSort.Add(tmpMp3ListePfadSort[i]);
          tmpMp3ListeAlbenSort.Sort(Sort_String2String1Titel_asc);
          //(Sortieren_String2String1Titel_asc);

          fBrowseListsNeedUpdate := False;

          // BrowseListen vorbereiten.
          InitAlbenlist(tmpMp3ListeAlbenSort, tmpAlleAlben);
          Generateartistlist(tmpMp3ListeArtistSort, tmpAlleArtists);
      end;
      1: begin
          // CoverFlow
          tmpMp3ListeArtistSort.Clear;
          tmpMp3ListeAlbenSort.Clear;
          for i := 0 to tmpMp3ListePfadSort.Count - 1 do
          begin
            tmpMp3ListeArtistSort.Add(tmpMp3ListePfadSort[i]);
            tmpMp3ListeAlbenSort.Add(tmpMp3ListePfadSort[i]);
          end;
          tmpMp3ListeArtistSort.Sort(Sort_CoverID);
          //(Sortieren_CoverID);
          tmpMp3ListeAlbenSort.Sort(Sort_CoverID);
          //(Sortieren_CoverID);

          // BrowseListen vorbereiten.
          GenerateCoverList(tmpMp3ListeArtistSort, tmpCoverList);
      end;
      2: begin
          // tagCloud
          tmpMp3ListeArtistSort.Clear;
          tmpMp3ListeAlbenSort.Clear;
          for i := 0 to tmpMp3ListePfadSort.Count - 1 do
          begin
              tmpMp3ListeArtistSort.Add(tmpMp3ListePfadSort[i]);
              tmpMp3ListeAlbenSort.Add(tmpMp3ListePfadSort[i]);
          end;
          // Note: We do not need sorted BrowseLists in the TagCloud
      end;
  end;

end;
{
    --------------------------------------------------------
    CleanUpDeadFilesFromVCLLists
    - This is called by the VCL-thread,
      not from the secondary update-thread!
    --------------------------------------------------------
}
procedure TMedienBibliothek.CleanUpDeadFilesFromVCLLists;
var i: Integer;
begin
    // Delete DeadFiles from AnzeigeListe (meaning: from the possible "real" lists behind this list)
    for i := 0 to DeadFiles.Count - 1 do
    begin
        LastBrowseResultList      .Extract(DeadFiles[i]);
        LastQuickSearchResultList .Extract(DeadFiles[i]);
        LastMarkFilterList        .Extract(DeadFiles[i]);
    end;
    // Delete DeadFiles from BibSearcher
    BibSearcher.RemoveAudioFilesFromLists(DeadFiles);
end;
{
    --------------------------------------------------------
    CleanUpDeadFiles
    --------------------------------------------------------
}
procedure TMedienBibliothek.fCleanUpDeadFiles;
var i: Integer;
    aAudioFile: TAudioFile;
    jas: TJustaString;
begin
  for i := 0 to DeadFiles.Count - 1 do
  begin
     aAudioFile := DeadFiles[i];
     FreeAndNil(aAudioFile);
  end;
  for i := 0 to DeadPlaylists.Count - 1 do
  begin
      jas := TJustaString(DeadPlaylists[i]);
      FreeAndNil(jas);
  end;
  DeadFiles.Clear;
  DeadPlaylists.Clear;
end;

{
    --------------------------------------------------------
    RefreshFiles
    - create a secondary thread
      However, during the whole execution the library will be blocked, as
      - Artists/Albums may change, so binary search on the audiofiles will fail
        so browsing is not possible
      - Quicksearch will also fail, as the TotalStrings do not necessarly match
        the AudioFiles
      Refreshing without blocking would be possible, but require a full copy of the
      AudioFiles, which will require much more RAM
    --------------------------------------------------------
}
procedure TMedienBibliothek.RefreshFiles_All;
var Dummy: Cardinal;
begin
  if StatusBibUpdate = 0 then
  begin
      UpdateFortsetzen := True;
      StatusBibUpdate := BIB_Status_ReadAccessBlocked;
      // reset Coversearch
      CoverArtSearcher.StartNewSearch;
      // start refreshing files
      fHND_RefreshFilesThread := (BeginThread(Nil, 0, @fRefreshFilesThread_All, Self, 0, Dummy));
  end;
end;
procedure TMedienBibliothek.RefreshFiles_Selected;
var Dummy: Cardinal;
begin
  if StatusBibUpdate = 0 then
  begin
      UpdateFortsetzen := True;
      StatusBibUpdate := BIB_Status_ReadAccessBlocked;
      // reset Coversearch
      CoverArtSearcher.StartNewSearch;
      // start refreshing files
      fHND_RefreshFilesThread := (BeginThread(Nil, 0, @fRefreshFilesThread_Selected, Self, 0, Dummy));
  end;
end;

{
    --------------------------------------------------------
    fRefreshFilesThread
    - the secondary thread will call the proper private method
    --------------------------------------------------------
}
procedure fRefreshFilesThread_All(MB: TMedienbibliothek);
begin
    MB.fRefreshFiles(MB.Mp3ListePfadSort);
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
    try
        CloseHandle(MB.fHND_RefreshFilesThread);
    except
    end;
end;
procedure fRefreshFilesThread_Selected(MB: TMedienbibliothek);
begin
    MB.fRefreshFiles(MB.UpdateList);
    MB.UpdateList.Clear;
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
    try
        CloseHandle(MB.fHND_RefreshFilesThread);
    except
    end;
end;
{
    --------------------------------------------------------
    fRefreshFilesThread
    - Block read access for the VCL
    --------------------------------------------------------
}
procedure TMedienBibliothek.fRefreshFiles(aRefreshList: TAudioFileList);
var i, freq, ges: Integer;
    AudioFile: TAudioFile;
    oldArtist, oldAlbum: UnicodeString;
    oldID: string;
    einUpdate: boolean;
    DeleteDataList: TObjectList;
    ct, nt: Cardinal;
begin
  // AudioFiles will be changed. Block everything.
  SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockReadAccess, 0); //
  SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNormal));
  SendMessage(MainWindowHandle, WM_MedienBib, MB_StartLongerProcess, Integer(pa_RefreshFiles));

  einUpdate := False;

  EnterCriticalSection(CSUpdate);
  ges := aRefreshList.Count;
  freq := Round(aRefreshList.Count / 100) + 1;
  ct := GetTickCount;
  for i := 0 to aRefreshList.Count - 1 do
  begin
        AudioFile := aRefreshList[i];
        if FileExists(AudioFile.Pfad) then
        begin
            AudioFile.FileIsPresent:=True;
            oldArtist := AudioFile.Strings[NempSortArray[1]];
            oldAlbum := AudioFile.Strings[NempSortArray[2]];
            oldID := AudioFile.CoverID;

            SendMessage(MainWindowHandle, WM_MedienBib, MB_RefreshAudioFile, lParam(AudioFile));


            if  (oldArtist <> AudioFile.Strings[NempSortArray[1]])
                OR (oldAlbum <> AudioFile.Strings[NempSortArray[2]])
                or (oldID <> AudioFile.CoverID)
            then
                einUpdate := true;
        end
        else
        begin
            AudioFile.FileIsPresent:=False;
            DeadFiles.Add(AudioFile);
        end;

        nt := GetTickCount;
        if (i mod freq = 0) or (nt > ct + 500) or (nt < ct) then
        begin
            ct := nt;
            SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressCurrentFileOrDirUpdate,
                            Integer(PWideChar(Format(_(MediaLibrary_RefreshingFilesInDir),
                                                  [ AudioFile.Ordner ]))));

            SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, Round(i/ges * 100));
            SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessSuccessCount, (i+1) - DeadFiles.Count);
            SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessFailCount, DeadFiles.Count);
        end;

        if Not UpdateFortsetzen then break;
  end;

  SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, 100);


  // first: adjust Browse&Search stuff for the new data
  if einUpdate then
  begin
      SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressShowHint, Integer(PChar(MediaLibrary_RefreshingFilesPreparingLibrary)));
      // Listen sortieren
      // With lParam = 1 only the caption of the StatusLabel is changed
      SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockWriteAccess, 1);

      case BrowseMode of
          0: begin
              Mp3ListeArtistSort.Sort(Sort_String1String2Titel_asc);
              Mp3ListeAlbenSort.Sort(Sort_String2String1Titel_asc);
              // BrowseListen neu f�llen
              SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockReadAccess, 1);
              GenerateArtistList(Mp3ListeArtistSort, AlleArtists);
              InitAlbenList(Mp3ListeAlbenSort, AlleAlben);
          end;
          1: begin
              Mp3ListeArtistSort.Sort(Sort_CoverID);
              Mp3ListeAlbenSort.Sort(Sort_CoverID);
              SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockReadAccess, 1);
              GenerateCoverList(Mp3ListeArtistSort, CoverList);
          end;
          2: begin
              // Nothing to do here. TagCloud will be rebuild in VCL-Thread
              // by MB_RefillTrees
              SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockReadAccess, 1);
          end;
      end;
      // Build TotalStrings
      BibSearcher.BuildTotalString(Mp3ListePfadSort);
      BibSearcher.BuildTotalLyricString(Mp3ListePfadSort);

      // Nachricht diesbzgl. an die VCL
      SendMessage(MainWindowHandle, WM_MedienBib, MB_RefillTrees, LParam(True));
  end;

  // After this: Handle missing files
  if DeadFiles.Count > 0 then
  begin
      // SendMessage(MainWindowHandle, WM_MedienBib, MB_DeadFilesWarning, LParam(DeadFiles.Count));
      DeleteDataList := TObjectList.Create(True);
      try
          fPrepareUserInputDeadFiles(DeleteDataList);
          SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressShowHint, Integer(PChar(_(MediaLibrary_SearchingMissingFilesComplete_PrepareUserInput))));
          SendMessage(MainWindowHandle, WM_MedienBib, MB_UserInputDeadFiles, lParam(DeleteDataList));
          // user can change DeleteDataList (set the DoDelete-property of the objects)
          // so: Change the DeadFiles-list and fill it with the files that should be deleted.
          fReFillDeadFilesByDataList(DeleteDataList);
      finally
          DeleteDataList.Free;
      end;

      if (DeadFiles.Count{ + DeadPlaylists.Count}) > 0 then
      // (we haven't checked for playlist during "refreshing files"
      begin
          fPrepareDeleteFilesUpdate;
          SwapLists;
          SendMessage(MainWindowHandle, WM_MedienBib, MB_CheckAnzeigeList, 0);
          fCleanUpDeadFiles;
          CleanUpTmpLists;
      end;

      SendMessage(MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free); // status: ok, thread finished
  end;

  LeaveCriticalSection(CSUpdate);

  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                        Integer(PChar(_(MediaLibrary_RefreshingFilesCompleteFinished ) )));

  // Status zur�cksetzen, Unblock library
  SendMessage(MainWindowHandle, WM_MedienBib, MB_UnBlock, 0);
  SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNoProgress));

  // Changed Setz. Ja...IMMER. Eine Abfrage, ob sich _irgendwas_ an _irgendeinem_ File
  // ge�ndert hat, f�hre ich nicht durch.
  Changed := True;
end;



{
    --------------------------------------------------------
    GetLyrics
    - Creates a secondary thread and load lyrics from LyricWiki.org
    --------------------------------------------------------
}
procedure TMedienBibliothek.GetLyricPriorities(out Prio1, Prio2: TLyricFunctionsEnum);
var i: TLyricFunctionsEnum;
begin
    Prio1 := LYR_NONE;
    Prio2 := LYR_NONE;
    for i := Low(TLyricFunctionsEnum) to High(TLyricFunctionsEnum) do
    begin
        if LyricPriorities[i] = 1 then
            Prio1 := i;
        if LyricPriorities[i] = 2 then
            Prio2 := i;
    end;
end;

procedure TMedienBibliothek.GetLyrics;
  var Dummy: Cardinal;
      Prio1, Prio2: TLyricFunctionsEnum;
begin
    // Status MUST be set outside
    // (the updatelist is filled in VCL-Thread)
    // But, to be sure:
    StatusBibUpdate := 1;
    UpdateFortsetzen := True;

    // Get the Priorities for the Lyric-Search-Methods
    GetLyricPriorities(Prio1, Prio2);
    EnterCriticalSection(CSLyricPriorities);
        fLyricFirstPriority  := Prio1;
        fLyricSecondPriority := Prio2;
    LeaveCriticalSection(CSLyricPriorities);

    fHND_GetLyricsThread := BeginThread(Nil, 0, @fGetLyricsThread, Self, 0, Dummy);
end;

{
    --------------------------------------------------------
    fGetLyricsThread
    - secondary thread
    Files the user wants to fill with lyrics are stored in the UpdateList,
    so CleanUpTmpLists must be called after getting Lyrics.
    --------------------------------------------------------
}
procedure fGetLyricsThread(MB: TMedienBibliothek);
begin
    MB.fGetLyrics;
    MB.CleanUpTmpLists;
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
    try
      CloseHandle(MB.fHND_GetLyricsThread);
    except
    end;
end;
{
    --------------------------------------------------------
    fGetLyrics
    - Block Update-Access
    --------------------------------------------------------
}
procedure TMedienBibliothek.fGetLyrics;
var i: Integer;
    aAudioFile: TAudioFile;
    LyricWikiResponse, backup: String;
    done, failed: Integer;
    Lyrics: TLyrics;
    aErr: TNempAudioError;
    ErrorOcurred, CurrentSuccess: Boolean;
    ErrorLog: TErrorLog;

    tmpLyricFirstPriority,tmpLyricSecondPriority  : TLyricFunctionsEnum;

begin
    SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockUpdateStart, 0);

    done := 0;
    failed := 0;
    SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNormal));
    SendMessage(MainWindowHandle, WM_MedienBib, MB_StartLongerProcess, Integer(pa_Searchlyrics));

    ErrorOcurred := False;

    Lyrics :=  TLyrics.create;
    try
            //Critical Section: Set Priorities
            EnterCriticalSection(CSLyricPriorities);
                tmpLyricFirstPriority := self.fLyricFirstPriority;
                tmpLyricSecondPriority := self.fLyricSecondPriority;
            LeaveCriticalSection(CSLyricPriorities);

            Lyrics.SetLyricSearchPriorities(tmpLyricFirstPriority, tmpLyricSecondPriority);

            // Lyrics suchen
            for i := 0 to UpdateList.Count - 1 do
            begin
                if not UpdateFortsetzen then break;

                aAudioFile := UpdateList[i];
                if FileExists(aAudioFile.Pfad)
                    AND aAudioFile.HasSupportedTagFormat
                then
                begin
                    // call the vcl, that we will edit this file now
                    SendMessage(MainWindowHandle, WM_MedienBib, MB_ThreadFileUpdate,
                            Integer(PWideChar(aAudioFile.Pfad)));

                    SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressCurrentFileOrDirUpdate,
                            Integer(PWideChar(Format(_(MediaLibrary_SearchingLyrics_JustFile),
                                                  [ aAudioFile.Dateiname ]))));

                    SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, Round(i/UpdateList.Count * 100));

                    aAudioFile.FileIsPresent:=True;

                    // possible ENetHTTPClientException is handled in Lyrics.GetLyris
                    LyricWikiResponse := Lyrics.GetLyrics(aAudiofile.Artist, aAudiofile.Titel);
                    if LyricWikiResponse <> '' then
                    begin
                        backup := String(aAudioFile.Lyrics);
                        // Sync with ID3tags (to be sure, that no ID3Tags are deleted)
                        aAudioFile.GetAudioData(aAudioFile.Pfad);
                        // Set new Lyrics
                        aAudioFile.Lyrics := UTF8Encode(LyricWikiResponse);
                        aErr := aAudioFile.WriteLyricsToMetaData(aAudioFile.Lyrics, True);
                        if aErr = AUDIOERR_None then
                        begin
                            inc(done);
                            CurrentSuccess := True;
                            Changed := True;
                        end else
                        begin
                            // discard new lyrics
                            aAudioFile.Lyrics := Utf8String(backup);
                            inc(failed);
                            CurrentSuccess := False;
                            ErrorOcurred := True;
                            // FehlerMessage senden
                            ErrorLog := TErrorLog.create(afa_LyricSearch, aAudioFile, aErr, false);
                            try
                                SendMessage(MainWindowHandle, WM_MedienBib, MB_ErrorLog, LParam(ErrorLog));
                            finally
                                ErrorLog.Free;
                            end;
                        end;
                    end
                    else
                    begin
                        inc(failed);
                        CurrentSuccess := False;
                        // as set by Lyrics.getLyrics, in case of an Exception
                        if Lyrics.ExceptionOccured then
                        begin
                            ErrorOcurred := True;  // Count Exceptions?
                            // Display Exception Message
                            SendMessage(MainWindowHandle, WM_MedienBib, MB_MessageForLog, LParam(Lyrics.ExceptionMessage));
                        end;

                    end;
                end
                else begin
                    if Not FileExists(aAudioFile.Pfad) then
                        aAudioFile.FileIsPresent:=False;
                    inc(failed);
                    CurrentSuccess := False;
                end;
                if CurrentSuccess then
                    SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessSuccessCount, done)
                else
                    SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessFailCount, failed);

            end;
    finally
            Lyrics.Free;
    end;

    // clear thread-used filename
    SendMessage(MainWindowHandle, WM_MedienBib, MB_ThreadFileUpdate, Integer(PWideChar('')));

    SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, 100);
    SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNoProgress));

    // Build TotalStrings
    SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockWriteAccess, 0);
    SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockReadAccess, 0);
    BibSearcher.BuildTotalSearchStrings(Mp3ListePfadSort);

    if ErrorOcurred then
    begin
        SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                Integer(PChar(_(MediaLibrary_SearchLyricsComplete_SomeErrors))));
        // display the Warning-Image
        SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessCompleteSomeErrors, 0);
    end else
    begin
          if done + failed = 1 then
          begin
              // ein einzelnes File wurde angefordert
              // Bei Misserfolg einen Hinweis geben.
              if (done = 0) then
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                      Integer(PChar(_(MediaLibrary_SearchLyricsComplete_SingleNotFound))))
              else
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                      Integer(PChar(_(MediaLibrary_SearchLyricsComplete_AllFound))))
          end else
          begin
              // mehrere Dateien wurden gesucht.
              if failed = 0 then
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                      Integer(PChar(_(MediaLibrary_SearchLyricsComplete_AllFound))))
              else
                  if done > 0.5 * (failed + done) then
                      // ganz gutes Ergebnis - mehr als die H�lfte gefunden
                      SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                          Integer(PChar(Format(_(MediaLibrary_SearchLyricsComplete_ManyFound), [done, done + failed]))))
                  else
                      if done > 0 then
                          // Nicht so tolles Ergebnis
                          SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                              Integer(PChar(Format(_(MediaLibrary_SearchLyricsComplete_FewFound), [done, done + failed]))))
                      else
                          SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                              Integer(PChar(_(MediaLibrary_SearchLyricsComplete_NoneFound))))
          end;
    end;
end;



{
    --------------------------------------------------------
    GetTags
    - Same as GetLyrics:
      Creates a secondary thread and get Tags from LastFM
    --------------------------------------------------------
}
procedure TMedienBibliothek.GetTags;
  var Dummy: Cardinal;
begin
    // Status MUST be set outside
    // (the updatelist is filled in VCL-Thread)
    // But, to be sure:
    StatusBibUpdate := 1;
    UpdateFortsetzen := True;
    // copy the Ignore- and Rename-Lists to make them thread-safe
    fPrepareGetTags;
    // start the thread
    fHND_GetTagsThread := BeginThread(Nil, 0, @fGetTagsThread, Self, 0, Dummy);
end;

procedure TMedienBibliothek.fPrepareGetTags;
var i: Integer;
    aTagMergeItem: TTagMergeItem;
begin
    fIgnoreListCopy.Clear;
    fMergeListCopy.Clear;
    for i := 0 to TagPostProcessor.IgnoreList.Count - 1 do
        fIgnoreListCopy.Add(TagPostProcessor.IgnoreList[i]);

    for i := 0 to TagPostProcessor.MergeList.Count-1 do
    begin
        aTagMergeItem := TTagMergeItem.Create(
            TTagMergeItem(TagPostProcessor.MergeList[i]).OriginalKey,
            TTagMergeItem(TagPostProcessor.MergeList[i]).ReplaceKey);
        fMergeListCopy.Add(aTagMergeItem);
    end;
end;
{
    --------------------------------------------------------
    fGetTagsThread
    - start a secondary thread
    --------------------------------------------------------
}
procedure fGetTagsThread(MB: TMedienBibliothek);
begin
    MB.fGetTags;
    MB.CleanUpTmpLists;
    // Todo: Rebuild TagCloud ??
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
    try
        CloseHandle(MB.fHND_GetTagsThread);
    except
    end;
end;
{
    --------------------------------------------------------
    fGetTags
    - getting the tags
    --------------------------------------------------------
}
procedure TMedienBibliothek.fGetTags;
var i: Integer;
    done, failed: Integer;
    af: TAudioFile;
    s, backup: String;
    aErr: TNempAudioError;
    ErrorOcurred, currentSuccess: Boolean;
    ErrorLog: TErrorLog;
begin
    done := 0;
    failed := 0;
    ErrorOcurred := false;

    SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNormal));

    // if UpdateList.Count > 1 then
        SendMessage(MainWindowHandle, WM_MedienBib, MB_StartLongerProcess, Integer(pa_SearchTags));

    for i := 0 to UpdateList.Count - 1 do
    begin
        if not UpdateFortsetzen then break;

        af := UpdateList[i];

        if FileExists(af.Pfad) AND af.HasSupportedTagFormat then
        begin
            // call the vcl, that we will edit this file now
            SendMessage(MainWindowHandle, WM_MedienBib, MB_ThreadFileUpdate,
                        Integer(PWideChar(af.Pfad)));

            SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressCurrentFileOrDirUpdate,
                            Integer(PWideChar(Format(_(MediaLibrary_SearchingTags_JustFile),
                                                      [af.Dateiname]))));

            //SendMessage(MainWindowHandle, WM_MedienBib, MB_TagsUpdateStatus,
            //            Integer(PWideChar(Format(_(MediaLibrary_SearchTagsStats), [done, done + failed]))));

            SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, Round(i/UpdateList.Count * 100));
            af.FileIsPresent:=True;

            // GetTags will create the IDHttp-Object
            s := BibScrobbler.GetTags(af);
            // 08.2017: s is a comma-separated list of tags now

            // bei einer exception ganz abbrechen??
            // nein, manchmal kommen ja auch BadRequests...???
            if trim(s) = '' then
            begin
                inc(failed);
                currentSuccess := False;

                if BibScrobbler.ExceptionOccured then
                begin
                    ErrorOcurred := True;  // Count Exceptions?
                    // Display Exception Message
                    SendMessage(MainWindowHandle, WM_MedienBib, MB_MessageForLog, LParam(BibScrobbler.ExceptionMessage));
                end;

            end else
            begin
                backup := String(af.RawTagLastFM);
                // process new Tags. Rename, delete ignored and duplicates.

                // Sync with ID3tags (to be sure, that no ID3Tags are deleted)
                af.GetAudioData(af.Pfad);

                // Set new Tags
                // change to medienbib.addnewtag (THREADED)
                // param false: do not ignore warnings but resolve inconsistencies
                // param true: use thread-safe copies of rule-lists
                AddNewTag(af, s, False, True);
                aErr := af.WriteRawTagsToMetaData(af.RawTagLastFM, True);

                if aErr = AUDIOERR_None then
                begin
                    Changed := True;
                    inc(done);
                    currentSuccess := True;
                end
                else
                begin
                    inc(failed);
                    currentSuccess := False;
                    ErrorOcurred := True;
                    // FehlerMessage senden
                    ErrorLog := TErrorLog.create(afa_TagSearch, af, aErr, false);
                    try
                        SendMessage(MainWindowHandle, WM_MedienBib, MB_ErrorLog, LParam(ErrorLog));
                    finally
                        ErrorLog.Free;
                    end;
                end;
            end;
        end else
        begin
            if Not FileExists(af.Pfad) then
                af.FileIsPresent:=False;
            inc(failed);
            currentSuccess := False;
        end;

        if CurrentSuccess then
            SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessSuccessCount, done)
        else
            SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessFailCount, failed);
    end;

    if done > 0 then
        SendMessage(MainWindowHandle, WM_MedienBib, MB_TagsSetTabWarning, 0);

    SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, 100);
    SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNoProgress));

    // clear thread-used filename
    SendMessage(MainWindowHandle, WM_MedienBib, MB_ThreadFileUpdate, Integer(PWideChar('')));


    if ErrorOcurred then
    begin
        SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                Integer(PChar(_(MediaLibrary_SearchTagsComplete_SomeErrors))));
        // display the Warning-Image
        SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessCompleteSomeErrors, 0);
    end else
    begin
          if done + failed = 1 then
          begin
              // ein einzelnes File wurde angefordert
              // Bei Mi�erfolg einen Hinweis geben.
              if (done = 0) then
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                      Integer(PChar(_(MediaLibrary_SearchTagsComplete_SingleNotFound))))
              else
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                      Integer(PChar(_(MediaLibrary_SearchTagsComplete_AllFound))))
          end else
          begin
              // mehrere Dateien wurden gesucht.
              if failed = 0 then
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                      Integer(PChar(_(MediaLibrary_SearchTagsComplete_AllFound))))
              else
                  if done > 0.5 * (failed + done) then
                      // ganz gutes Ergebnis - mehr als die H�lfte gefunden
                      SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                          Integer(PChar(Format(_(MediaLibrary_SearchTagsComplete_ManyFound), [done, done + failed]))))
                  else
                      if done > 0 then
                          // Nicht so tolles Ergebnis
                          SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                              Integer(PChar(Format(_(MediaLibrary_SearchTagsComplete_FewFound), [done, done + failed]))))
                      else
                          SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                              Integer(PChar(_(MediaLibrary_SearchTagsComplete_NoneFound))))
          end;
    end;
end;




{
    --------------------------------------------------------
    UpdateId3tags
    - Updating the ID3Tags
      Used by the TagCloud-Editor
    --------------------------------------------------------
}
procedure TMedienBibliothek.UpdateId3tags;
var Dummy: Cardinal;
begin
    // Status MUST be set outside
    // (the updatelist is filled in VCL-Thread)
    // But, to be sure:
    StatusBibUpdate := 1;
    UpdateFortsetzen := True;
    fHND_UpdateID3TagsThread := BeginThread(Nil, 0, @fUpdateID3TagsThread, Self, 0, Dummy);
end;



procedure fUpdateID3TagsThread(MB: TMedienBibliothek);
begin
    MB.fUpdateId3tags;

    // Note: CleanUpTmpLists and stuff is not necessary here.
    // We did not change the library, we "just" changed the ID3-Tags in some files
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UnBlock, 0);
    try
        CloseHandle(MB.fHND_UpdateID3TagsThread);
    except
    end;
end;

procedure TMedienBibliothek.fUpdateId3tags;
var i, freq, ges: Integer;
    af: TAudioFile;
    aErr: TNempAudioError;
    ErrorOcurred: Boolean;
    ErrorLog: TErrorLog;
    ct, nt: Cardinal;
    errCount, inconCount: Integer;
    newTags: UTF8String;
begin
    SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNormal));
    SendMessage(MainWindowHandle, WM_MedienBib, MB_StartLongerProcess, Integer(pa_UpdateMetadata));

    ErrorOcurred := False;

    ges := UpdateList.Count;
    freq := Round(UpdateList.Count / 100) + 1;
    ct := GetTickCount;
    errCount := 0;

    for i := 0 to UpdateList.Count - 1 do
    begin
        if not UpdateFortsetzen then break;

        af := UpdateList[i];

        if FileExists(af.Pfad) then
        begin
            // call the vcl, that we will edit this file now
            SendMessage(MainWindowHandle, WM_MedienBib, MB_ThreadFileUpdate,
                        Integer(PWideChar(af.Pfad)));

            nt := GetTickCount;
            if (i mod freq = 0) or (nt > ct + 500) or (nt < ct) then
            begin
                ct := nt;
                SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, Round(i/ges * 100));
                // display current item in progress-label
                SendMessage(MainWindowHandle, WM_MedienBib, MB_RefreshTagCloudFile,
                        Integer(PWideChar(Format(MediaLibrary_CloudUpdateStatus, [af.Dateiname]))));
                // display success/fail
                SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessSuccessCount, i - errCount);
                SendMessage(MainWindowHandle, WM_MedienBib, MB_CurrentProcessFailCount, errCount);
            end;

            af.FileIsPresent := True;

            newTags := af.RawTagLastFM;
            // Sync with ID3tags (to be sure, that no ID3Tags are deleted)
            af.GetAudioData(af.Pfad);
            af.RawTagLastFM := newTags;

            aErr := af.WriteRawTagsToMetaData(af.RawTagLastFM, True);
            if aErr = AUDIOERR_None then
            begin
                af.ID3TagNeedsUpdate := False;
                Changed := True;
            end else
            begin
                inc(errCount);
                ErrorOcurred := True;
                ErrorLog := TErrorLog.create(afa_TagCloud, af, aErr, false);
                try
                    SendMessage(MainWindowHandle, WM_MedienBib, MB_ErrorLog, LParam(ErrorLog));
                finally
                    ErrorLog.Free;
                end;
            end;
        end else
        begin
            // not an unexpected error, but the file could not be updated, as it's currently not available
            inc(errCount);
        end;
    end;

    SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, 100);
    SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNoProgress));

    // this will reset the status of the MenuItem indicating the warning for inconsistent files
    SendMessage(MainWindowHandle, WM_MedienBib, MB_RefreshTagCloudFile, Integer(PWideChar('')));


    // present a summary of this operation in the progress window
    if ErrorOcurred then
    begin
        SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                Integer(PChar(_(MediaLibrary_InconsistentFiles_SomeErrors))));
        // display the Warning-Image
        SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessCompleteSomeErrors, 0);
    end else
    begin
          if Updatefortsetzen then
          begin
              // user *did not* aborted the operation.
              if errCount = 0 then
                  // everything is fine
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete, Integer(PChar(MediaLibrary_InconsistentFiles_Completed_Success)))
              else
              begin
                  // some files are still inconsitent
                  inconCount := CountInconsistentFiles;
                  SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                          Integer(PChar( Format(_(MediaLibrary_InconsistentFiles_Completed_SomeFailed),[inconCount]) )));
              end;
          end else
          begin
              // user *did* click on "Abort"
              // some ID3Tags are still inconsistent with the files in the library
              inconCount := CountInconsistentFiles;
              SendMessage(MainWindowHandle, WM_MedienBib, MB_UpdateProcessComplete,
                      Integer(PChar( Format(_(MediaLibrary_InconsistentFiles_Abort),[inconCount]) )));
          end;
    end;

    // clear thread-used filename
    SendMessage(MainWindowHandle, WM_MedienBib, MB_ThreadFileUpdate, Integer(PWideChar('')));

end;


{
    --------------------------------------------------------
    UpdateId3tags
    - Updating the ID3Tags
      Used by the TagCloud-Editor
    --------------------------------------------------------
}
procedure TMedienBibliothek.BugFixID3Tags;
var Dummy: Cardinal;
begin
    // Status MUST be set outside
    // (the updatelist is filled in VCL-Thread)
    // But, to be sure:
    StatusBibUpdate := 1;
    UpdateFortsetzen := True;
    fHND_BugFixID3TagsThread := BeginThread(Nil, 0, @fBugFixID3TagsThread, Self, 0, Dummy);
end;



procedure fBugFixID3TagsThread(MB: TMedienBibliothek);
begin
    MB.fBugFixID3Tags;
    // Note: CleanUpTmpLists and stuff is not necessary here.
    // We did not change the library, we "just" changed the ID3-Tags in some files
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
    SendMessage(MB.MainWindowHandle, WM_MedienBib, MB_UnBlock, 0);
    try
        CloseHandle(MB.fHND_BugFixID3TagsThread);
    except
    end;
end;

procedure TMedienBibliothek.fBugFixID3Tags;
var i, f: Integer;
    af: TAudioFile;
    id3: TID3v2Tag;
    FrameList: TObjectList;
    ms: TMemoryStream;
    privateOwner: AnsiString;
    LogList: TStringList;
begin
    SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNormal));

    LogList := TStringList.Create;
    try
        LogList.Add('Fixing ID3Tags. ');
        LogList.Add(DateTimeToStr(now));
        LogList.Add('Number of files to check: ' + IntToStr(UpdateList.Count));
        LogList.Add('---------------------------');

        for i := 0 to UpdateList.Count - 1 do
        begin

            if not UpdateFortsetzen then
            begin
                LogList.Add('Cancelled by User at file ' + IntToStr(i));
                break;
            end;

            af := UpdateList[i];

            if FileExists(af.Pfad) then
            begin
                // call the vcl, that we will edit this file now
                SendMessage(MainWindowHandle, WM_MedienBib, MB_ThreadFileUpdate,
                            Integer(PWideChar(af.Pfad)));
                SendMessage(MainWindowHandle, WM_MedienBib, MB_ProgressRefreshJustProgressbar, Round(i/UpdateList.Count * 100));

                SendMessage(MainWindowHandle, WM_MedienBib, MB_RefreshTagCloudFile,
                        Integer(PWideChar(
                            Format(MediaLibrary_CloudUpdateStatus,
                            [{Round(i/UpdateList.Count * 100),} af.Dateiname]))));


                af.FileIsPresent := True;

                id3 := TID3v2Tag.Create;
                try
                    // Read the tag from the file
                    id3.ReadFromFile(af.Pfad);

                    // Get all private Frames in the ID3Tag
                    FrameList := id3.GetAllPrivateFrames; // List is Created in this method

                    // delete everything except the 'NEMP/Tags'-Private Frames
                    // (from this list only, not from the ID3Tag ;-) )
                    for f := FrameList.Count - 1 downto 0 do
                    begin
                        ms := TMemoryStream.Create;
                        try
                            (FrameList[f] as TID3v2Frame).GetPrivateFrame(privateOwner, ms);
                        finally
                            ms.Free;
                        end;
                        if privateOwner <> 'NEMP/Tags' then
                            FrameList.Delete(f);
                    end;

                    if FrameList.Count > 1 then
                    begin
                        LogList.Add('Duplicate Entry: ' + af.Pfad);
                        LogList.Add('Count: ' + IntToStr(FrameList.Count));
                        // Oops, we have duplicate 'NEMP/Tags' in the file :(
                        for f := FrameList.Count - 1 downto 0 do
                            // Delete all these Frames
                            id3.DeleteFrame(TID3v2Frame(FrameList[f]));

                        // Set New Private Frame
                        if length(af.RawTagLastFM) > 0 then
                        begin
                            ms := TMemoryStream.Create;
                            try
                                ms.Write(af.RawTagLastFM[1], length(af.RawTagLastFM));
                                id3.SetPrivateFrame('NEMP/Tags', ms);
                            finally
                                ms.Free;
                            end;
                        end else
                            // delete Tags-Frame
                            id3.SetPrivateFrame('NEMP/Tags', NIL);

                        // Update the File
                        id3.WriteToFile(af.Pfad);
                        LogList.Add('...fixed');
                        LogList.Add('');
                    end;
                    FrameList.Free;
                finally
                    id3.Free;
                end;
                Changed := True;
            end;
        end;
        LogList.Add('Done.');
        LogList.SaveToFile(SavePath + 'ID3TagBugFix.log', TEncoding.Unicode);
    finally
        LogList.Free;
    end;

    SendMessage(MainWindowHandle, WM_MedienBib, MB_SetWin7TaskbarProgress, Integer(fstpsNoProgress));

    SendMessage(MainWindowHandle, WM_MedienBib, MB_RefreshTagCloudFile, Integer(PWideChar('')));

    // clear thread-used filename
    SendMessage(MainWindowHandle, WM_MedienBib, MB_ThreadFileUpdate,
                    Integer(PWideChar('')));
end;
{
    --------------------------------------------------------
    BuildTotalString
    BuildTotalLyricString
    - Build Strings for Accelerated Search directly, not via tmp-Strings
    Note: This MUST be done in VCL-Thread!
    --------------------------------------------------------
}
procedure TMedienBibliothek.BuildTotalString;
begin
    EnterCriticalSection(CSUpdate);
    BibSearcher.BuildTotalString(Mp3ListePfadSort);
    LeaveCriticalSection(CSUpdate);
end;
procedure TMedienBibliothek.BuildTotalLyricString;
begin
    EnterCriticalSection(CSUpdate);
    BibSearcher.BuildTotalLyricString(Mp3ListePfadSort);
    LeaveCriticalSection(CSUpdate);
end;

{
    --------------------------------------------------------
    DeleteAudioFile
    DeletePlaylist
    - Delete an AudioFile/Playlist from the library
    Run in VCL-Thread
    --------------------------------------------------------
}
function TMedienBibliothek.DeleteAudioFile(aAudioFile: tAudioFile): Boolean;
begin
//  result := StatusBibUpdate = 0;
// ??? Status MUST be set to 3 before calling this, as we have an "Application.ProcessMessages"
//     in the calling Method PM_ML_DeleteSelectedClick

  result := true;

  if aAudioFile = CurrentAudioFile then
      currentAudioFile := Nil;

  LastBrowseResultList      .Extract(aAudioFile);
  LastQuickSearchResultList .Extract(aAudioFile);
  LastMarkFilterList        .Extract(aAudioFile);

  /// AnzeigeListe2.Extract(aAudioFile);
  if AnzeigeShowsPlaylistFiles then
  begin
      PlaylistFiles.Extract(aAudioFile);
  end
  else
  begin
      Mp3ListePfadSort.Extract(aAudioFile);
      Mp3ListeArtistSort.Extract(aAudioFile);
      Mp3ListeAlbenSort.Extract(aAudioFile);
      tmpMp3ListePfadSort.Extract(aAudioFile);
      tmpMp3ListeArtistSort.Extract(aAudioFile);
      tmpMp3ListeAlbenSort.Extract(aAudioFile);
      BibSearcher.RemoveAudioFileFromLists(aAudioFile);
      Changed := True;
  end;
  FreeAndNil(aAudioFile);
end;
function TMedienBibliothek.DeletePlaylist(aPlaylist: TJustAString): boolean;
    procedure lDeletePlaylistFromList(aList: TObjectList);
    var i: Integer;
        currentJString: TJustaString;
    begin
        for i := 0 to aList.Count - 1 do
        begin
            currentJString := TJustaString(aList[i]);
            if (currentJString.DataString = aPlaylist.DataString)
               AND (currentJString.AnzeigeString = aPlaylist.AnzeigeString)
            then
            begin
                aList.Delete(i);
                break;
            end;
        end;
    end;
begin
    result := StatusBibUpdate = 0;
    if StatusBibUpdate <> 0 then exit;

    lDeletePlaylistFromList(tmpAllPlaylistsPfadSort);
    lDeletePlaylistFromList(AllPlaylistsPfadSort);
    lDeletePlaylistFromList(AllPlaylistsNameSort);
    lDeletePlaylistFromList(Alben);
    Changed := True;
    FreeAndNil(aPlaylist);
end;
{
    --------------------------------------------------------
    Abort
    - Set UpdateFortsetzen to false, to abort a running update-process
    --------------------------------------------------------
}
procedure TMedienBibliothek.Abort;
begin
  // when we get in "long VCL-actions" an exception,
  // the final MedienBib.StatusBibUpdate := 0; will not be called
  // so Nemp will never close
  // this is not 1000% "safe" with thread, but should be ok
  if not UpdateFortsetzen then
      StatusBibUpdate := 0;

  FileSearchAborted := True;
  // this is the main-code in this method
  if StatusBibUpdate > 0 then
  begin
      UpdateFortsetzen := False;
  end;
end;
{
    --------------------------------------------------------
    ResetRatings
    - Set the ratings of all AudioFiles back to 0.
    Note: Ratings in the ID3-Tags are untouched!
    --------------------------------------------------------
}
(*
procedure TMedienBibliothek.ResetRatings;
var i: Integer;
begin
  if StatusBibUpdate >= 2 then exit;
  EnterCriticalSection(CSUpdate);
  for i := 0 to Mp3ListeArtistSort.Count - 1 do
  begin
      (Mp3ListeArtistSort[i] as T--AudioFile).Rating := 0;
      (Mp3ListeArtistSort[i] as T--AudioFile).PlayCounter := 0;
  end;
  Changed := True;
  LeaveCriticalSection(CSUpdate);
end;
*)


{
    --------------------------------------------------------
    ValidKeys
    - Check, whether Key1 and Key2 matches strings[sortarray[1/2]]
      runs in VCL-Thread
    --------------------------------------------------------
}
function TMedienBibliothek.ValidKeys(aAudioFile: TAudioFile): Boolean;
begin
    result := (aAudioFile.Key1 = aAudioFile.Strings[NempSortArray[1]])
          AND (aAudioFile.Key2 = aAudioFile.Strings[NempSortArray[2]]);

    if Not result then
        fBrowseListsNeedUpdate := True;
end;

{
    --------------------------------------------------------
    HandleChangedCoverID
    - After a Cover-download the Files are not sorted by CoverID
      so we should resort them before merging with new files.
    --------------------------------------------------------
}
procedure TMedienBibliothek.HandleChangedCoverID;
begin
    fBrowseListsNeedUpdate := True;
end;

procedure TMedienBibliothek.ChangeCoverID(oldID, newID: String);
var afList: TAudioFileList;
    i: Integer;
begin
    afList := TAudioFileList.Create(False);
    try
        GetTitelListFromCoverID(afList, oldID);
        for i := 0 to afList.Count - 1 do
            // set the new ID
            afList[i].CoverID := NewID;
    finally
        afList.Free;
    end;

    // handle the Changes
    HandleChangedCoverID;
    Changed := True;
end;

procedure TMedienBibliothek.ChangeCoverIDUnsorted(oldID, newID: String);
var afList: TAudioFileList;
    i: Integer;
begin
    afList := TAudioFileList.Create(False);
    try
        GetTitelListFromCoverIDUnsorted(afList, oldID);
        for i := 0 to afList.Count - 1 do
            // set the new ID
            afList[i].CoverID := NewID;
    finally
        afList.Free;
    end;

    // handle the Changes
    HandleChangedCoverID;
    Changed := True;
end;

{
    --------------------------------------------------------
    Methods to add new Tags to an AudioFile with respect to the Ignore/Merge-Lists
    --------------------------------------------------------
}
function TMedienBibliothek.AddNewTagConsistencyCheck(aAudioFile: TAudioFile; newTag: String): TTagConsistencyError;
var currentTagList, newTagList: TStringlist;
    i: Integer;
    replaceTag: String;
begin
    result := CONSISTENCY_OK;
    TagPostProcessor.LogList.Clear;

    currentTagList := TStringlist.Create;
    try
        currentTagList.Text := String(aAudioFile.RawTagLastFM);
        currentTagList.CaseSensitive := False;

        newTagList := TStringlist.Create;
        try
              if CommasInString(NewTag) then
                  // replace commas with linebreaks first
                  NewTag := ReplaceCommasbyLinebreaks(Trim(NewTag));
              // fill the Stringlist with the new Tags (probably only one)
              newTagList.Text := Trim(NewTag);

              for i := 0 to newTagList.Count-1 do
              begin
                  // duplicate in the list itself?
                  if newTagList.IndexOf(newTagList[i]) < i then
                  begin
                      if result = CONSISTENCY_OK then
                          result := CONSISTENCY_HINT; // Duplicate found, no user action required
                      TagPostProcessor.LogList.Add(Format(TagManagement_TagDuplicateInput, [newTagList[i]]));
                  end;
                  // Does it already exist?
                  if currentTagList.IndexOf(newTagList[i]) > -1 then
                  begin
                      if result = CONSISTENCY_OK then
                          result := CONSISTENCY_HINT;  // Duplicate found, no user action required
                      TagPostProcessor.LogList.Add(Format(TagManagement_TagAlreadyExists, [newTagList[i]]));
                  end;
                  // is it on the Igore list?
                  if TagPostProcessor.IgnoreList.IndexOf(newTagList[i]) > -1 then
                  begin
                      result := CONSISTENCY_WARNING; // new Tag is on the Ignore List, User action required
                      TagPostProcessor.LogList.Add(Format(TagManagement_TagIsOnIgnoreList, [newTagList[i]]));
                  end;
                  // is it on the Merge list?
                  replaceTag := GetRenamedTag(newTagList[i], TagPostProcessor.MergeList);
                  if replaceTag <> '' then
                  begin
                      result := CONSISTENCY_WARNING; // new tag is on the Merge list, User action required
                      TagPostProcessor.LogList.Add(Format(TagManagement_TagIsOnRenameList, [newTagList[i], replaceTag]));
                  end;
              end;
        finally
            newTagList.Free;
        end;
    finally
        currentTagList.Free;
    end;
end;


function TMedienBibliothek.AddNewTag(aAudioFile: TAudioFile; newTag: String; IgnoreWarnings: Boolean; Threaded: Boolean = False): TTagError;
var currentTagList, newTagList: TStringlist;
    i: Integer;
    replaceTag: String;
    localIgnoreList: TStringList;
    localMergeList: TObjectList;
begin
    result := TAGERR_NONE;
    currentTagList := TStringlist.Create;
    try
        currentTagList.Text := String(aAudioFile.RawTagLastFM);
        currentTagList.CaseSensitive := False;

        if Threaded then
        begin
            localIgnoreList := fIgnoreListCopy;
            localMergeList  := fMergeListCopy;
        end else
        begin
            localIgnoreList := TagPostProcessor.IgnoreList;
            localMergeList  := TagPostProcessor.MergeList;
        end;

        newTagList := TStringlist.Create;
        try
              if CommasInString(NewTag) then
                  // replace commas with linebreaks first
                  NewTag := ReplaceCommasbyLinebreaks(Trim(NewTag));
              // fill the Stringlist with the new Tags (probably only one)
              newTagList.Text := Trim(NewTag);

              // process the tags
              for i := newTagList.Count-1 downto 0 do
              begin
                  // is it on the Igore list?
                  if (localIgnoreList.IndexOf(newTagList[i]) > -1) and (not IgnoreWarnings) then
                      newTagList.Delete(i)
                  else
                  begin
                      // is it on the Merge list?
                      replaceTag := GetRenamedTag(newTagList[i], localMergeList);
                      if (replaceTag <> '') and (not IgnoreWarnings) then
                          newTagList[i] := replaceTag;
                  end;
              end;

              // delete duplicate entries in the new taglist
              for i := newTagList.Count-1 downto 0 do
                  if newTagList.IndexOf(newTagList[i]) < i then
                      newTagList.Delete(i);
              // delete the entries the file is already tagged with
              for i := newTagList.Count-1 downto 0 do
                  if currentTagList.IndexOf(newTagList[i]) > -1 then
                      newTagList.Delete(i);

              // add the new tags to the current tags
              newTag := Trim(newTagList.Text);
              if newTag <> '' then
              begin
                  Changed := True;
                  if aAudioFile.RawTagLastFM = '' then
                      aAudioFile.RawTagLastFM := UTF8String(newTag)
                  else
                  begin
                      // fixed some compiler warnings regarding implicit string casts
                      //cleanup current RawTag (to be sure)
                      aAudioFile.RawTagLastFM := UTF8String(trim(String(aAudioFile.RawTagLastFM)));
                      // add new Tag
                      aAudioFile.RawTagLastFM := aAudioFile.RawTagLastFM + #13#10 + UTF8String(newTag);
                  end;
              end;
        finally
            newTagList.Free;
        end;
    finally
        currentTagList.Free;
    end;
end;

{
procedure TMedienBibliothek.RemoveTag(aAudioFile: TAudioFile; oldTag: String);
var currentTagList: TStringlist;
    idx: Integer;
begin
    currentTagList := TStringlist.Create;
    try
        currentTagList.Text := String(aAudioFile.RawTagLastFM);
        currentTagList.CaseSensitive := False;

        // get the index of oldTag and delete it
        idx := currentTagList.IndexOf(oldTag);
        if idx > -1 then
            currentTaglist.Delete(idx);
        // set RawTags again
        aAudioFile.RawTagLastFM := UTF8String(Trim(currentTaglist.Text));
        Changed := True;
    finally
        currenttagList.Free;
    end;
end;       }


{
    --------------------------------------------------------
    AudioFileExists
    PlaylistFileExists
    GetAudioFileWithFilename
    - Check, whether fa file is already in the library
    --------------------------------------------------------
}
function TMedienBibliothek.AudioFileExists(aFilename: UnicodeString): Boolean;
begin
    result := binaersuche(Mp3ListePfadSort, ExtractFileDir(aFilename), ExtractFileName(aFilename), 0,Mp3ListePfadSort.Count-1) > -1;
end;
function TMedienBibliothek.PlaylistFileExists(aFilename: UnicodeString): Boolean;
begin
    result := BinaerPlaylistSuche(AllPlaylistsPfadSort, aFilename, 0, AllPlaylistsPfadSort.Count-1) > -1;
end;
function TMedienBibliothek.GetAudioFileWithFilename(aFilename: UnicodeString): TAudioFile;
var idx: Integer;
begin
  idx := binaersuche(Mp3ListePfadSort,ExtractFileDir(aFilename), ExtractFileName(aFilename),0,Mp3ListePfadSort.Count-1);
  if idx = -1 then
    result := Nil
  else
    result := Mp3ListePfadSort[idx];
end;


{
    --------------------------------------------------------
    GenerateArtistList
    - Get all different Artists from the library.
    Used in the left of the two browse-trees
    --------------------------------------------------------
}
procedure TMedienBibliothek.GenerateArtistList(Source: TAudioFileList; Target: TObjectlist);
var i: integer;
  aktualArtist, lastArtist: UnicodeString;
begin
  for i := 0 to Target.Count - 1 do
    TJustaString(Target[i]).Free;

  Target.Clear;
  Target.Add(TJustastring.create(BROWSE_PLAYLISTS));
  Target.Add(TJustastring.create(BROWSE_RADIOSTATIONS));
  Target.Add(TJustastring.create(BROWSE_ALL));

  if Source.Count < 1 then exit;

  case NempSortArray[1] of
      siFileAge: aktualArtist := Source[0].FileAgeString;
      siOrdner : aktualArtist := Source[0].Ordner;// + '\';
  else
      aktualArtist := Source[0].Strings[NempSortArray[1]];
  end;

  // Copy current value for "artist" to key1
  if NempSortArray[1] = siFileAge then
      Source[0].Key1 := Source[0].FileAgeSortString
  else
      Source[0].Key1 := aktualArtist;

  lastArtist := aktualArtist;
  if lastArtist = '' then
      Target.Add(TJustastring.create(Source[0].Key1 , AUDIOFILE_UNKOWN))
  else
      Target.Add(TJustastring.create(Source[0].Key1 , lastArtist));

  for i := 1 to Source.Count - 1 do
  begin
    //if NempSortArray[1] = siFileAge then
    //    aktualArtist := (Source[i] as T--AudioFile).FileAgeString
    //else
    //    aktualArtist := (Source[i] as T--AudioFile).Strings[NempSortArray[1]];
    case NempSortArray[1] of
        siFileAge: aktualArtist := Source[i].FileAgeString;
        siOrdner : aktualArtist := Source[i].Ordner;// + '\';
    else
        aktualArtist := Source[i].Strings[NempSortArray[1]];
    end;

    // Copy current value for "artist" to key1
    if NempSortArray[1] = siFileAge then
        Source[i].Key1 := Source[i].FileAgeSortString
    else
        Source[i].Key1 := aktualArtist;

    if NOT AnsiSameText(aktualArtist, lastArtist) then
    begin
        lastArtist := aktualArtist;
        if lastArtist <> '' then
            Target.Add(TJustastring.create(Source[i].Key1 , lastArtist));
    end;
  end;

 { if (NempSortArray[1] <> siOrdner) then
  begin
    i := 3;      // <All> auslassen
    while (i < Target.Count) and (  AnsiCompareText(TJustastring(Target[i]).AnzeigeString, AUDIOFILE_UNKOWN) < 0  ) do
      inc(i);

    start := i;
    if (start < Target.Count) and (  AnsiCompareText(TJustastring(Target[i]).AnzeigeString, AUDIOFILE_UNKOWN) = 0  ) then
    begin
        for i := start downto 4 do
        begin
            tmpJaS := TJustastring(Target[i]);
            Target[i] := Target[i-1];
            Target[i-1] := tmpJaS;
        end;
    end;
  end;
  }


end;
{
    --------------------------------------------------------
    InitAlbenlist
    - Get all different Albums from the library.
    Used in the right of the two browse lists, if Artist=<All> is selected
    --------------------------------------------------------
}
procedure TMedienBibliothek.InitAlbenlist(Source: TAudioFileList; Target: TStringList);
var i: integer;
  aktualAlbum, lastAlbum: UnicodeString;
begin
  // Initiiere eine Liste mit allen Alben
  Target.Clear;
  Target.Add(BROWSE_ALL);
  if Source.Count < 1 then exit;

  if NempSortArray[2] = siFileAge then
      aktualAlbum := Source[0].FileAgeString
  else
      aktualAlbum := Source[0].Strings[NempSortArray[2]];

  // Copy current value for "album" to key2
  if NempSortArray[2] = siFileAge then
      Source[0].Key2 := Source[0].FileAgeSortString
  else
      Source[0].Key2 := aktualAlbum;


  lastAlbum := aktualAlbum;
  // Ung�ltige Alben nicht einf�gen
//  if lastAlbum = '' then  // Hier noch eine bessere �berpr�fung einbauen ???      (*)
//      Target.Add(AUDIOFILE_UNKOWN)
//  else
      Target.Add(lastAlbum);

  for i := 1 to Source.Count - 1 do
  begin
    // check for "new album"
      if NempSortArray[2] = siFileAge then
        aktualAlbum := Source[i].FileAgeString
      else
        aktualAlbum := Source[i].Strings[NempSortArray[2]];

    // Copy current value for "album" to key2
      if NempSortArray[2] = siFileAge then
          Source[i].Key2 := Source[i].FileAgeSortString
      else
          Source[i].Key2 := aktualAlbum;

    if NOT AnsiSameText(aktualAlbum, lastAlbum) then
    begin
      lastAlbum := aktualAlbum;
      //if lastAlbum <> '' then  // Hier noch eine bessere �berpr�fung einbauen ???   (*)
      //  Target.Add(lastAlbum);
//      if lastAlbum = '' then  // Hier noch eine bessere �berpr�fung einbauen ???      (*)
//          Target.Add(AUDIOFILE_UNKOWN)
//      else
          Target.Add(lastAlbum);

    end;
  end;
end;
{
    --------------------------------------------------------
    InitPlayListsList
    - Sort the Playlists by Name
    Used by the right browse-tree, when Playlists are selected
    --------------------------------------------------------
}
procedure TMedienBibliothek.InitPlayListsList;
var i: Integer;
begin
    AllPlaylistsNameSort.Clear;
    for i := 0 to AllPlaylistsPfadSort.Count - 1 do
        AllPlaylistsNameSort.Add(AllPlaylistsPfadSort[i]);

    AllPlaylistsNameSort.Sort(PlaylistSort_Name);
end;


procedure TMedienBibliothek.SortCoverList(aList: TObjectList);
begin
    case MissingCoverMode of
        0: begin
            case CoverSortorder of
                1: aList.Sort(CoverSort_ArtistMissingFirst);
                2: aList.Sort(CoverSort_AlbumMissingFirst);
                3: aList.Sort(CoverSort_GenreMissingFirst);
                4: aList.Sort(CoverSort_JahrMissingFirst);
                5: aList.Sort(CoverSort_GenreYearMissingFirst);
                6: aList.Sort(CoverSort_DirectoryArtistMissingFirst);
                7: aList.Sort(CoverSort_DirectoryAlbumMissingFirst);
                8: aList.Sort(CoverSort_FileAgeAlbumMissingFirst);
                9: aList.Sort(CoverSort_FileAgeArtistMissingFirst);
            end;
        end;
        2: begin
            case CoverSortorder of
                1: aList.Sort(CoverSort_ArtistMissingLast);
                2: aList.Sort(CoverSort_AlbumMissingLast);
                3: aList.Sort(CoverSort_GenreMissingLast);
                4: aList.Sort(CoverSort_JahrMissingLast);
                5: aList.Sort(CoverSort_GenreYearMissingLast);
                6: aList.Sort(CoverSort_DirectoryArtistMissingLast);
                7: aList.Sort(CoverSort_DirectoryAlbumMissingLast);
                8: aList.Sort(CoverSort_FileAgeAlbumMissingLast);
                9: aList.Sort(CoverSort_FileAgeArtistMissingLast);
            end;
        end;
    else
        case CoverSortorder of
            1: aList.Sort(CoverSort_Artist);
            2: aList.Sort(CoverSort_Album);
            3: aList.Sort(CoverSort_Genre);
            4: aList.Sort(CoverSort_Jahr);
            5: aList.Sort(CoverSort_GenreYear);
            6: aList.Sort(CoverSort_DirectoryArtist);
            7: aList.Sort(CoverSort_DirectoryAlbum);
            8: aList.Sort(CoverSort_FileAgeAlbum);
            9: aList.Sort(CoverSort_FileAgeArtist);
        end;
    end;
end;
{
    --------------------------------------------------------
    GenerateCoverList
    - Get all Cover-IDs from the Library
    Used for Coverflow
    --------------------------------------------------------
}
procedure TMedienBibliothek.GenerateCoverList(Source: TAudioFileList; Target: TObjectlist);
var i: integer;
  aktualID, lastID: String;
  newCover: TNempCover;
  aktualAudioFile: tAudioFile;
  AudioFilesWithSameCover: TAudioFileList;

begin
  for i := 0 to Target.Count - 1 do
    TNempCover(Target[i]).Free;
  Target.Clear;

  EnterCriticalSection(CSAccessBackupCoverList);
  fBackupCoverlist.Clear;
  LeaveCriticalSection(CSAccessBackupCoverList);

  newCover := TNempCover.Create(True);
  newCover.ID := 'all';
  newCover.key := 'all';
  newCover.Artist := CoverFlowText_VariousArtists;
  Newcover.Album  := CoverFlowText_WholeLibrary; //'Your media-library';
  Target.Add(NewCover);

  if Source.Count < 1 then
  begin
    CoverArtSearcher.PrepareMainCover(Target);
    exit;
  end;

  AudioFilesWithSameCover := TAudioFileList.Create(False);

  aktualAudioFile := Source[0];
  aktualAudioFile.Key1 := aktualAudioFile.CoverID;   // copy ID to key1
  aktualID := aktualAudioFile.CoverID;
  lastID := aktualID;

  newCover := TNempCover.Create;
  newCover.ID := aktualAudioFile.CoverID;
  newCover.key := newCover.ID;
  NewCover.Artist := aktualAudioFile.Artist;
  NewCover.Album := aktualAudioFile.Album;
  NewCover.Year := StrToIntDef(aktualAudioFile.Year, 0);
  NewCover.Genre := aktualAudioFile.Genre;
  Target.Add(NewCover);

  AudioFilesWithSameCover.Add(aktualAudioFile);

  for i := 1 to Source.Count - 1 do
  begin
      aktualAudioFile := Source[i];
      aktualAudioFile.Key1 := aktualAudioFile.CoverID;   // copy ID to key1
      aktualID := aktualAudioFile.CoverID;
      if SameText(aktualID, lastID) then
      begin
          AudioFilesWithSameCover.Add(aktualAudioFile);
      end else
      begin
          // Checklist (liste, cover)
          newCover.GetCoverInfos(AudioFilesWithSameCover);

          // to do here: if info = <N/A> then ignore this cover, i.e. delete it from the list.
          if HideNACover and NewCover.InvalidData then
          begin
                  // discard current cover
                  NewCover.Free;
                  Target.Delete(Target.Count - 1);
          end;

          // Neues Cover erstellen und neue Liste anfangen
          lastID := aktualID;
          newCover := TNempCover.Create;
          newCover.ID := aktualAudioFile.CoverID;
          newCover.key := newCover.ID;
          NewCover.Year := StrToIntDef(aktualAudioFile.Year, 0);
          NewCover.Genre := aktualAudioFile.Genre;
          Target.Add(NewCover);
          AudioFilesWithSameCover.Clear;
          AudioFilesWithSameCover.Add(aktualAudioFile);
      end;
  end;

  // Check letzte List
  newCover.GetCoverInfos(AudioFilesWithSameCover);
  AudioFilesWithSameCover.Free;

  // Coverliste sortieren
  SortCoverList(Target);

  CoverArtSearcher.PrepareMainCover(Target);

end;

procedure TMedienBibliothek.GenerateCoverListFromSearchResult(Source: TAudioFileList;
  Target: TObjectlist);
var i: Integer;
    newCover: TNempCover;
    AudioFilesWithSameCover: TAudioFileList;
    currentAudioFile: TAudioFile;
    currentID, lastID: String;

begin
    for i := 0 to Target.Count - 1 do
        TNempCover(Target[i]).Free;
    Target.Clear;

    newCover := TNempCover.Create(True);
    newCover.ID := 'searchresult';
    newCover.key := 'searchresult';
    newCover.Artist := CoverFlowText_VariousArtists; // 'Various artists';
    Newcover.Album := CoverFlowText_WholeLibrarySearchResults;
    Target.Add(NewCover);

    if Source.Count < 1 then
    begin
        CoverArtSearcher.PrepareMainCover(Target);
        exit;
    end;

    AudioFilesWithSameCover := TAudioFileList.Create(False);
    try
        i := 0;
        while i <= Source.Count - 1 do
        begin
            currentAudioFile := Source[i];
            currentAudioFile.Key1 := currentAudioFile.CoverID;   // copy ID to key1

            // create cover with ID of the current AudioFile
            currentID := currentAudioFile.CoverID;
            lastID := currentID;

            newCover := TNempCover.Create;
            newCover.ID := currentAudioFile.CoverID;
            newCover.key := newCover.ID;
            NewCover.Artist := currentAudioFile.Artist;
            NewCover.Album := currentAudioFile.Album;
            NewCover.Year := StrToIntDef(currentAudioFile.Year, 0);
            NewCover.Genre := currentAudioFile.Genre;
            Target.Add(NewCover);
            // get all AudioFiles with this ID from the COMPLETE List
            GetTitelListFromCoverID(AudioFilesWithSameCover, currentID);

            // get Infos from these files
            newCover.GetCoverInfos(AudioFilesWithSameCover);

            // to do here: if info = <N/A> then ignore this cover, i.e. delete it from the list.
            if HideNACover and NewCover.InvalidData then
            begin
                // discard current cover
                NewCover.Free;
                Target.Delete(Target.Count - 1);
            end;

            // get index of first audiofile with a different CoverID
            repeat
                inc (i);
            until (i > Source.Count - 1) or (Source[i].CoverID <> currentID);
        end; // while

        // Coverliste sortieren
        SortCoverList(Target);
        CoverArtSearcher.PrepareMainCover(Target);

    finally
        AudioFilesWithSameCover.Free;
    end;

end;


procedure TMedienBibliothek.SetBaseMarkerList(aList: TAudioFileList);
begin
    if limitMarkerToCurrentFiles then
        BaseMarkerList := aList
    else
        BaseMarkerList := Mp3ListePfadSort;
end;

{
    --------------------------------------------------------
    ReBuildBrowseLists
    - used when user changes the criteria for browsing
      (e.g. from Artist-Album to Directory-Artist
    --------------------------------------------------------
}
Procedure TMedienBibliothek.ReBuildBrowseLists;
begin
  Mp3ListeArtistSort.Sort(Sort_String1String2Titel_asc);
  Mp3ListeAlbenSort.Sort(Sort_String2String1Titel_asc);
  GenerateArtistList(Mp3ListeArtistSort, AlleArtists);

  InitAlbenList(Mp3ListeAlbenSort, AlleAlben);
  //...ein Senden dieser nachricht ist daher ok.
  // d.h. einfach die B�ume neuf�llen. Ein markieren der zuletzt markierten Knoten ist unsinnig
  SendMessage(MainWindowHandle, WM_MedienBib, MB_RefillTrees, LParam(False));
end;
{
    --------------------------------------------------------
    ReBuildCoverList
    - update the coverlist
    --------------------------------------------------------
}
procedure TMedienBibliothek.ReBuildCoverList(FromScratch: Boolean = True);
var i: Integer;
    newCover: TNempCover;
begin
  if FromScratch or (fBackupCoverlist.Count = 0) then
  begin
      if FromScratch then
      begin
          Mp3ListeArtistSort.Sort(Sort_CoverID);
          Mp3ListeAlbenSort.Sort(Sort_CoverID);
      end;
      GenerateCoverList(Mp3ListeArtistSort, CoverList); // fBackupCoverlist is cleared there
  end
  else
  begin
      for i := 0 to CoverList.Count - 1 do
          TNempCover(CoverList[i]).Free;
      CoverList.Clear;

      EnterCriticalSection(CSAccessBackupCoverList);
      for i := 0 to fBackupCoverlist.Count - 1 do
      begin
          newCover := TNempCover.Create;
          newCover.Assign(TNempCover(fBackupCoverlist[i]));
          CoverList.Add(newCover);
      end;
      fBackupCoverlist.Clear;
      LeaveCriticalSection(CSAccessBackupCoverList);
  end;
end;

procedure TMedienBibliothek.ReBuildCoverListFromList(aList: TAudioFileList);
var tmpList: TAudioFileList;
    i: integer;
    newCover: TNempCover;
begin

    // Backup Coverlist if BackUpList.Count = 0
    if fBackupCoverlist.Count = 0 then
    begin
        EnterCriticalSection(CSAccessBackupCoverList);
        for i := 0 to CoverList.Count - 1 do
        begin
            newCover := TNempCover.Create;
            newCover.Assign(TNempCover(CoverList[i]));
            fBackupCoverlist.Add(newCover);
        end;
        LeaveCriticalSection(CSAccessBackupCoverList);
    end;

    // copy Items, SourceList should not be sorted
    tmpList := TAudioFileList.Create(False);
    try
        for i := 0 to aList.Count - 1 do
            tmpList.Add(aList[i]);

        tmpList.Sort(Sort_CoverID);

        GenerateCoverListFromSearchResult(tmpList, CoverList);
    finally
        tmpList.Free;
    end;
end;

{
    --------------------------------------------------------
    ReBuildTagCloud
    - update the TagCloud
    --------------------------------------------------------
}
procedure TMedienBibliothek.ReBuildTagCloud;
begin
    // Build the Tagcloud.
    TagCloud.BuildCloud(Mp3ListePfadSort, Nil, True);
end;

procedure TMedienBibliothek.RestoreTagCloudNavigation;
begin
    TagCloud.RestoreNavigation(Mp3ListeArtistSort);
end;

procedure TMedienBibliothek.GetTopTags(ResultCount: Integer; Offset: Integer; Target: TObjectList; HideAutoTags: Boolean = False);
begin
    TagCloud.GetTopTags(ResultCount, Offset, Mp3ListeArtistSort, Target, HideAutoTags);
end;


{
    --------------------------------------------------------
    RepairBrowseListsAfterDelete
    RepairBrowseListsAfterChange
    - Repairing the Browselist
    --------------------------------------------------------
}
procedure TMedienBibliothek.RepairBrowseListsAfterDelete;
begin

    case BrowseMode of
        0: begin
          GenerateArtistList(Mp3ListeArtistSort, AlleArtists);
          InitAlbenList(Mp3ListeAlbenSort, AlleAlben);
        end;
        1: GenerateCoverList(Mp3ListeArtistSort, CoverList);
        2: ;// nothing to do
  end;
  // nicht senden SendMessage(MainWindowHandle, WM_RefillTrees, 0, 0);
  // Denn: Es sollen jetzt die alten Knoten wieder markiert werden
end;
Procedure TMedienBibliothek.RepairBrowseListsAfterChange;
begin
  case BrowseMode of
      0: begin
          Mp3ListeArtistSort.Sort(Sort_String1String2Titel_asc);
          Mp3ListeAlbenSort.Sort(Sort_String2String1Titel_asc);
          GenerateArtistList(Mp3ListeArtistSort, AlleArtists);
          InitAlbenList(Mp3ListeAlbenSort, AlleAlben);
      end;
      1: begin
          Mp3ListeArtistSort.Sort(Sort_CoverID);
          Mp3ListeAlbenSort.Sort(Sort_CoverID);
          GenerateCoverList(Mp3ListeArtistSort, CoverList);
      end;
      2: ;// nothing to to
  end;
end;

{
    --------------------------------------------------------
    GetStartEndIndex
    - Get the indices, where the wanted "name" can be found
    --------------------------------------------------------
}
procedure TMedienBibliothek.GetStartEndIndex(Liste: TAudioFileList; name: UnicodeString; Suchart: integer; var Start: integer; var Ende: Integer);
var einIndex: integer;
  min, max:integer;
  NameWithoutSlash: String;
begin
  // Bereich festlegen, in dem gesucht werden darf.
  min := Start;
  max := Ende;
  case Suchart of
        SEARCH_ARTIST:
                begin
                  if NempSortArray[1] = siOrdner then
                  begin
                      NameWithoutSlash := ExcludeTrailingPathDelimiter(name);
                      einIndex := BinaerArtistSuche_JustContains(Liste, NameWithoutSlash, Start, Ende)
                  end
                  else
                      einIndex := BinaerArtistSuche(Liste, name, Start, Ende);

                  Start := EinIndex;
                  Ende := EinIndex;
                  if EinIndex = -1 then begin
                  exit;
                  end;

                  if NempSortArray[1] = siOrdner then
                  begin
                      while (Start > min) AND (Pos(IncludeTrailingPathDelimiter(name),Liste[Start-1].Key1 + '\') = 1) do
                          dec(Start);
                      while (Ende < max) AND (Pos(IncludeTrailingPathDelimiter(name),Liste[Ende+1].Key1 + '\') = 1) do
                          inc(Ende);
                  end else begin
                      // note: AnsiSameText uses correct Unicode
                      while (Start > min) AND (AnsiSameText(name, Liste[Start-1].Key1)) do
                          dec(Start);
                      while (Ende < max) AND (AnsiSameText(name, Liste[Ende+1].Key1)) do
                          inc(Ende);
                  end;
                  //ShowMessage('Artists* ' +  InttoStr(Start) + ' - ' + Inttostr(Ende) + ': ' + Inttostr(Ende - Start));
        end;
        SEARCH_ALBUM: begin
                  // Suchart : Search_album
                  if NempSortArray[2] = siOrdner then
                  begin
                      NameWithoutSlash := ExcludeTrailingPathDelimiter(name);
                      einIndex := BinaerAlbumSuche_JustContains(Liste, NameWithoutSlash, Start, Ende);
                  end
                  else
                    einIndex := BinaerAlbumSuche(Liste, name, Start, Ende);

                  Start := EinIndex;
                  Ende := EinIndex;
                  if EinIndex = -1 then begin
                      exit;
                  end;
                  if NempSortArray[2] = siOrdner then
                  begin
                      while (Start > min) AND (Pos(IncludeTrailingPathDelimiter(name),Liste[Start-1].Key2 + '\') = 1) do
                          dec(Start);
                      while (Ende < max) AND (Pos(IncludeTrailingPathDelimiter(name),Liste[Ende+1].Key2 + '\') = 1) do
                          inc(Ende);
                  end else begin
                      while (Start > min) AND (AnsiSameText(Liste[Start-1].Key2,name)) do
                          dec(Start);
                      while (Ende < max) AND (AnsiSameText(Liste[Ende+1].Key2,name)) do
                          inc(Ende);
                  end;

                  //ShowMessage(InttoStr(Start) + ' - ' + Inttostr(Ende) + ': ' + Inttostr(Ende - Start));
        end;
        SEARCH_COVERID: begin
           // s.u.   (GetStartEndIndexCover)
        end;
  end;
end;
{
    --------------------------------------------------------
    GetStartEndIndexCover
    - Get the indices, where the wanted "name" can be found
    --------------------------------------------------------
}
procedure TMedienBibliothek.GetStartEndIndexCover(Liste: TAudioFileList; aCoverID: String; var Start: integer; var Ende: Integer);
var einIndex: integer;
  min, max:integer;
begin
  min := Start;
  max := Ende;
  einIndex := BinaerCoverIDSuche(Liste, aCoverID, Start, Ende);
  Start := EinIndex;
  Ende := EinIndex;
  while (Start > min) AND (AnsiSameText(Liste[Start-1].Key1, aCoverID)) do dec(Start);
  while (Ende < max) AND (AnsiSameText(Liste[Ende+1].Key1, aCoverID)) do inc(Ende);
end;

{
    --------------------------------------------------------
    GetAlbenList
    - When Browsing the left tree, fill the right tree
    --------------------------------------------------------
}
procedure TMedienBibliothek.GetAlbenList(Artist: UnicodeString);
var i,start, Ende: integer;
  aktualAlbum, lastAlbum: UnicodeString;
  tmpstrlist: TStringList;
begin
  for i := 0 to Alben.Count - 1 do
    TJustaString(Alben[i]).Free;

  Alben.Clear;

  if Artist = BROWSE_ALL then
  begin
      for i:=0 to AlleAlben.Count - 1 do
      begin
          if UnKownInformation(AlleAlben[i]) then
              Alben.Add(TJustAString.create(AlleAlben[i], AUDIOFILE_UNKOWN))
          else
              Alben.Add(TJustAString.create(AlleAlben[i]));
      end;
  end else
  if Artist = BROWSE_RADIOSTATIONS then
  begin
      for i := 0 to RadioStationList.Count - 1 do
          Alben.Add(TJustaString.create(TStation(RadioStationList[i]).URL, TStation(RadioStationList[i]).Name))
  end else
  if Artist = BROWSE_PLAYLISTS then
  begin
      for i:=0 to AllPlaylistsNameSort.Count - 1 do
          Alben.Add(TJustastring.create(
              TJustastring(AllPlaylistsNameSort[i]).DataString,
              TJustastring(AllPlaylistsNameSort[i]).AnzeigeString));
  end
  else
  begin
      Alben.Add(TJustastring.create(BROWSE_ALL));

      // nur die Alben eines Artists einf�gen
      // Voraussetzung: Sortierung der Liste nach Artist -> Album
      // Dann bei jedem Albumwechsel das Album einf�gen
      Start := 0;
      Ende := Mp3ListeArtistSort.Count-1;

      GetStartEndIndex(Mp3ListeArtistSort, Artist, SEARCH_ARTIST, Start, Ende);

      //showmessage(inttostr(start) + '-' + inttostr(ende));


      if (start > Mp3ListeArtistSort.Count-1) OR (Mp3ListeArtistSort.Count < 1)  or (start < 0) then exit;

      if NempSortArray[1] = siOrdner then
      begin
          // Es sollen alle Alben aufgelistet werden, die in dem Ordner oder einem
          // Unterordner enthalten sind.
          // da die Liste prim�r nach Ordner, dann erst nach Album sortiert ist, kann
          // es da beim "einfachen" Einf�gen zu doppelten Eintr�gen kommen, und/oder
          // zu einer unsortierten Liste. Daher:

          // Ja, der Trick mit der tmp-Liste ist etwas unsch�n. Das kann
          // man evtl. besser machen
          tmpstrlist := TStringList.Create;
          tmpstrlist.Sorted := True;
          tmpstrlist.Duplicates := dupIgnore;
          for i:= Start to Ende do
            tmpstrlist.Add(Mp3ListeArtistSort[i].Key2);

          for i := 0 to tmpstrlist.Count - 1 do
            Alben.Add(TJustastring.create(tmpstrlist[i]));

          tmpstrlist.Free;
      end else
      begin
            // Hier funktioniert das einfache EInf�gen
            aktualAlbum := Mp3ListeArtistSort[start].Key2;
            lastAlbum := aktualAlbum;
            if NempSortArray[2] = siFileAge then
                Alben.Add(TJustastring.create(lastAlbum, Mp3ListeArtistSort[start].FileAgeString ))
            else
            begin
                if lastAlbum = '' then
                    Alben.Add(TJustastring.create(lastAlbum, AUDIOFILE_UNKOWN))
                else
                    Alben.Add(TJustastring.create(lastAlbum));
            end;


            for i := start+1 to Ende do
            begin
              aktualAlbum := Mp3ListeArtistSort[i].Key2;
              if NOT AnsiSameText(aktualAlbum, lastAlbum) then
              begin
                lastAlbum := aktualAlbum;
                if NempSortArray[2] = siFileAge then
                    Alben.Add(TJustastring.create(lastAlbum, Mp3ListeArtistSort[i].FileAgeString))
                else
                begin
                    if lastAlbum = '' then
                        Alben.Add(TJustastring.create(lastAlbum, AUDIOFILE_UNKOWN))
                    else
                        Alben.Add(TJustastring.create(lastAlbum));
                end;
              end;
            end;
      end;
  end;

end;


{
    --------------------------------------------------------
    GetTitelList
    - Get the matching titles for "Artist" and "Album"
    --------------------------------------------------------
}
Procedure TMedienBibliothek.GetTitelList(Target: TAudioFileList; Artist: UnicodeString; Album: UnicodeString);
var i, Start, Ende: integer;
begin
  Target.Clear;
  Start := 0;
  Ende := Mp3ListeArtistSort.Count - 1;

  if Artist <> BROWSE_ALL then
  begin
      if Album <> BROWSE_ALL then
      begin
          GetStartEndIndex(Mp3ListeAlbenSort, Album, SEARCH_ALBUM, Start, Ende);
          if NempSortArray[2] = siOrdner then
          begin
              // the area between start - ende is not necessarly sorted by "artist" now
              // as we could have different sub-directories within the selected dir
              // so we need to do a linear search here
              for i := start to Ende do
                  if AnsiSameText(Mp3ListeAlbenSort[i].Key1, Artist) then
                      Target.Add(Mp3ListeAlbenSort[i]);
          end else
          begin
              GetStartEndIndex(Mp3ListeAlbenSort, Artist, SEARCH_ARTIST, Start, Ende);
              if (start > Mp3ListeAlbenSort.Count - 1) OR (Mp3ListeAlbenSort.Count < 1) or (start < 0) then exit;
              for i := Start to Ende do
                  Target.Add(Mp3ListeAlbenSort[i]);
          end;
      end else
      begin
        //alle Titel eines Artists - Jetzt ist wieder die Artist-Liste gefragt
        GetStartEndIndex(Mp3ListeArtistSort, Artist, SEARCH_ARTIST, Start, Ende);
        if (start > Mp3ListeArtistSort.Count - 1) OR (Mp3ListeArtistSort.Count < 1) or (start < 0) then exit;
        for i := Start to Ende do
          Target.Add(Mp3ListeArtistSort[i]);
      end;
  end else
  begin
        //Artist ist <Alle>. d.h. es werden alle Titel oder alle Titel eines Albums gew�nscht.
        // d.h. jetzt ist die Sortierung Album ben�tigt!!
        if Album <> BROWSE_ALL then
          GetStartEndIndex(Mp3ListeAlbenSort , Album, SEARCH_ALBUM, Start, Ende);
        if start = -1 then exit;
        for i := Start to Ende do
          Target.Add(Mp3ListeAlbenSort[i]);
  end;
end;

function TMedienBibliothek.IsAutoSortWanted: Boolean;
begin
    result := AlwaysSortAnzeigeList
          And
          ( (AnzeigeListe.Count {+ AnzeigeListe2.Count} < 5000) or (Not SkipSortOnLargeLists));
end;

{
    --------------------------------------------------------
    GenerateAnzeigeListe
    - GetTitelList with Target=Anzeigeliste
    (has gone a little complicated since allowing webradio and playlists there...)
    --------------------------------------------------------
}
Procedure TMedienBibliothek.GenerateAnzeigeListe(Artist: UnicodeString; Album: UnicodeString);//; UpdateQuickSearchList: Boolean = True);
var i: Integer;
begin
  AnzeigeListIsCurrentlySorted := False;
  if Artist = BROWSE_PLAYLISTS then
  begin
      BibSearcher.DummyAudioFile.Titel := MainForm_NoTitleInformationAvailable;

      // Playlist Datei in PlaylistFiles laden.
      PlaylistFiles.Clear;

      LastBrowseResultList.Clear;
      AnzeigeListe := LastBrowseResultList;
      SetBaseMarkerList(LastBrowseResultList);

      // bugfix Nemp 4.7.1
      // (Bug created in 4.7, in context of the label-click-search-stuff)
      CurrentAudioFile := Nil;

      if FileExists(Album) then
      begin
          LoadPlaylistFromFile(Album, PlaylistFiles, AutoScanPlaylistFilesOnView, fPlaylistDriveManager);

          AnzeigeShowsPlaylistFiles := True;
          DisplayContent := DISPLAY_BrowsePlaylist;

          for i := 0 to PlaylistFiles.Count - 1 do
              LastBrowseResultList.Add(PlaylistFiles[i]);

          SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList,  0)
      end else
          SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList,  100);

  end else
  if Artist = BROWSE_RADIOSTATIONS then
  begin
      BibSearcher.DummyAudioFile.Titel := MainForm_NoTitleInformationAvailable;

      LastBrowseResultList.Clear;
      AnzeigeListe := LastBrowseResultList;
      SetBaseMarkerList(LastBrowseResultList);

      SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList,  0);
  end else
  begin
      BibSearcher.DummyAudioFile.Titel := MainForm_NoSearchresults;
      AnzeigeShowsPlaylistFiles := False;
      DisplayContent := DISPLAY_BrowseFiles;

      AnzeigeListe := LastBrowseResultList;
      SetBaseMarkerList(LastBrowseResultList);

      GetTitelList(LastBrowseResultList, Artist, Album);
      if IsAutoSortWanted then
          SortAnzeigeliste;

      SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList,  0);
  end;
end;
{
    --------------------------------------------------------
    GetTitelListFromCoverID
    - Same as above, for Coverflow
    --------------------------------------------------------
}
procedure TMedienBibliothek.GetTitelListFromCoverID(Target: TAudioFileList; aCoverID: String);
var i, Start, Ende: integer;
begin
  Target.Clear;

  if aCoverID = 'searchresult' then
  begin
      // special case: Show all Files in Quicksearchlist
      for i := 0 to BibSearcher.QuickSearchResults.Count - 1 do
          Target.Add(BibSearcher.QuickSearchResults[i]);
  end else
  begin
      Start := 0;
      Ende := Mp3ListeArtistSort.Count - 1;

      if (aCoverID <> 'all') then // and (aCoverID <> '') then
        GetStartEndIndexCover(Mp3ListeArtistSort, aCoverID, Start, Ende);

      if (start > Mp3ListeArtistSort.Count - 1) OR (Mp3ListeArtistSort.Count < 1) or (start < 0) then
          exit;

      for i := Start to Ende do
          Target.Add(Mp3ListeArtistSort[i]);
  end;
end;
{
    --------------------------------------------------------
    GetTitelListFromCoverIDUnsorted
    - Same result as above, but can be used when NOT in Coverflow mode by the DetailForm when changing Library-Cover
    --------------------------------------------------------
}
procedure TMedienBibliothek.GetTitelListFromCoverIDUnsorted(Target: TAudioFileList; aCoverID: String);
var i: Integer;
begin
    for i := 0 to Mp3ListeArtistSort.Count - 1 do
    begin
        if Mp3ListeArtistSort[i].CoverID = aCoverID then
            Target.Add(Mp3ListeArtistSort[i]);
    end;
end;

procedure TMedienBibliothek.GetTitelListFromDirectoryUnsorted(Target: TAudioFileList; aDirectory: String);
var i: Integer;
begin
    for i := 0 to Mp3ListeArtistSort.Count - 1 do
    begin
        if Mp3ListeArtistSort[i].Ordner = aDirectory then
            Target.Add(Mp3ListeArtistSort[i]);
    end;
end;

{
    --------------------------------------------------------
    GenerateAnzeigeListeFromCoverID
    - Same as above, for Coverflow
    --------------------------------------------------------
}
procedure TMedienBibliothek.GenerateAnzeigeListeFromCoverID(aCoverID: String);
begin
  AnzeigeListIsCurrentlySorted := False;

  //LastBrowseResultList.Clear; // done in GetTitelListFromCoverID
  AnzeigeListe := LastBrowseResultList;
  SetBaseMarkerList(LastBrowseResultList);
  GetTitelListFromCoverID(LastBrowseResultList, aCoverID);

  AnzeigeShowsPlaylistFiles := False;
  DisplayContent := DISPLAY_BrowseFiles;
  AnzeigeListIsCurrentlySorted := False;
  if IsAutoSortWanted then
      SortAnzeigeliste;

  SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList,  0);
end;

procedure TMedienBibliothek.RestoreAnzeigeListeAfterQuicksearch;
begin
    AnzeigeListe := LastBrowseResultList;
    SetBaseMarkerList(LastBrowseResultList);
    SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList,  0);
end;

{
    --------------------------------------------------------
    GenerateAnzeigeListeFromTagCloud
    - Same as above, for TagCloud
      this is called when teh user clicks a Tag in the cloud,
      not in the breadcrumb-navigation
    --------------------------------------------------------
}
procedure TMedienBibliothek.GenerateAnzeigeListeFromTagCloud(aTag: TTag; BuildNewCloud: Boolean);
var i: Integer;
begin
  if not assigned(aTag) then exit;

  AnzeigeListIsCurrentlySorted := False;

  LastBrowseResultList.Clear;
  AnzeigeListe := LastBrowseResultList;
  SetBaseMarkerList(LastBrowseResultList);

  if aTag = TagCloud.ClearTag then
      for i := 0 to Mp3ListeArtistSort.Count - 1 do
          LastBrowseResultList.Add(Mp3ListeArtistSort[i])
  else
      // we need no binary search or stuff here. The Tag saves all its AudioFiles.
      for i := 0 to aTag.AudioFiles.Count - 1 do
          LastBrowseResultList.Add(aTag.AudioFiles[i]);

  if BuildNewCloud then
      TagCloud.BuildCloud(Mp3ListeArtistSort, aTag, False);
      // Note: Parameter Mp3ListeArtistSort is not used in this method, as the Filelist of aTag is used!


  AnzeigeShowsPlaylistFiles := False;
  DisplayContent := DISPLAY_BrowseFiles;

  AnzeigeListIsCurrentlySorted := False;
  if IsAutoSortWanted then
      SortAnzeigeliste;
  ///FillQuickSearchList;
  SendMessage(MainWindowHandle, WM_MedienBib, MB_ReFillAnzeigeList,  0);
end;

procedure TMedienBibliothek.GenerateDragDropListFromTagCloud(aTag: TTag; Target: TAudioFileList);
var i: Integer;
begin
    if not assigned(aTag) then exit;

    Target.Clear;

    if aTag = TagCloud.ClearTag then
        for i := 0 to Mp3ListeArtistSort.Count - 1 do
          Target.Add(Mp3ListeArtistSort[i])
    else
        // we need no binary search or stuff here. The Tag saves all its AudioFiles.
        for i := 0 to aTag.AudioFiles.Count - 1 do
            Target.Add(aTag.AudioFiles[i]);
end;

{
    --------------------------------------------------------
    GetCoverWithPrefix
    - Get the first/next matching cover
    Used by OnKeyDown of the CoverScrollbar
    --------------------------------------------------------
}
function TMedienBibliothek.GetCoverWithPrefix(aPrefix: UnicodeString; Startidx: Integer): Integer;
var nextidx: Integer;
    aCover: TNempCover;
    erfolg: Boolean;
begin
  nextIdx := Startidx;
  result := StartIdx;

  erfolg := False;
  repeat
    aCover := Coverlist[nextIdx] as TNempCover;
    if AnsiStartsText(aPrefix, aCover.Artist) or AnsiStartsText(aPrefix, aCover.Album)
    then
    begin
      result := nextIdx;
      erfolg := True;
    end;
    nextIdx := (nextIdx + 1) Mod (Coverlist.Count);
  until erfolg or (nextIdx = StartIdx);
end;



{
    --------------------------------------------------------
    GlobalQuickSearch
    CompleteSearch
    - Search for files in the library.
    --------------------------------------------------------
}
procedure TMedienBibliothek.GlobalQuickSearch(Keyword: UnicodeString; AllowErr: Boolean);
begin
    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    BibSearcher.GlobalQuickSearch(Keyword, AllowErr);
    LeaveCriticalSection(CSUpdate);
end;
procedure TMedienBibliothek.CompleteSearch(Keywords: TSearchKeyWords);
begin
    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    BibSearcher.CompleteSearch(KeyWords);
    LeaveCriticalSection(CSUpdate);
end;
procedure TMedienBibliothek.CompleteSearchNoSubStrings(Keywords: TSearchKeyWords);
begin
    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    BibSearcher.CompleteSearchNoSubStrings(KeyWords);
    LeaveCriticalSection(CSUpdate);
end;


procedure TMedienBibliothek.IPCSearch(Keyword: UnicodeString);
begin
    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    BibSearcher.IPCQuickSearch(Keyword);
    LeaveCriticalSection(CSUpdate);
end;

procedure TMedienBibliothek.GlobalQuickTagSearch(KeyTag: UnicodeString);
begin
    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    BibSearcher.GlobalQuickTagSearch(KeyTag);
    LeaveCriticalSection(CSUpdate);
end;

procedure TMedienBibliothek.QuickSearchShowAllFiles;
begin
    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    BibSearcher.ShowAllFiles;
    LeaveCriticalSection(CSUpdate);
end;

procedure TMedienBibliothek.EmptySearch(Mode: Integer);
begin
    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    BibSearcher.EmptySearch(Mode);
    LeaveCriticalSection(CSUpdate);
end;
procedure TMedienBibliothek.ShowMarker(aIndex: Byte);
begin
    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    BibSearcher.SearchMarker(aIndex, BaseMarkerList);
    LeaveCriticalSection(CSUpdate);
end;

{
    --------------------------------------------------------
    GetFilesInDir
    - Get all files in the library within the given directory
    --------------------------------------------------------
}


procedure TMedienBibliothek.GetFilesInDir(aDirectory: UnicodeString; ClearExistingView: Boolean);
var i: Integer;
    tmpList: TObjectList;
begin
  if StatusBibUpdate >= 2 then exit;
  EnterCriticalSection(CSUpdate);

  if AnzeigeShowsPlaylistFiles then
      MessageDLG((Medialibrary_GUIError1), mtError, [MBOK], 0)
  else
  begin
      tmpList := TObjectList.Create(False);
      try
          if not ClearExistingView then
          begin
              // add currently listed files to the tmpList
              for i := 0 to AnzeigeListe.Count - 1 do
                  tmpList.Add(AnzeigeListe[i]);
          end;

          for i := 0 to MP3ListeArtistSort.Count-1 do
              if Mp3ListeArtistSort[i].Ordner = aDirectory then
                  tmpList.Add(Mp3ListeArtistSort[i]);

          SendMessage(MainWindowHandle, WM_MedienBib, MB_ShowSearchResults, lParam(tmpList));
      finally
          tmpList.Free;
      end;
  end;

  LeaveCriticalSection(CSUpdate);
end;

{
    --------------------------------------------------------
    AddSorter
    - Add new/modify first element of SortParams: Array[0..SORT_MAX] of TCompareRecord;
    --------------------------------------------------------
}
procedure TMedienBibliothek.AddSorter(TreeHeaderColumnTag: Integer; FlipSame: Boolean = True);
var NewSortMethod: TAudioFileCompare;
    i: Integer;
begin
    case TreeHeaderColumnTag of
        CON_ARTIST              : NewSortMethod := AFCompareArtist;
        CON_TITEL               : NewSortMethod := AFCompareTitle;
        CON_ALBUM               : NewSortMethod := AFCompareAlbum;
        CON_DAUER               : NewSortMethod := AFCompareDuration;
        CON_BITRATE             : NewSortMethod := AFCompareBitrate;
        CON_CBR                 : NewSortMethod := AFCompareCBR;
        CON_MODE                : NewSortMethod := AFCompareChannelMode;
        CON_SAMPLERATE          : NewSortMethod := AFCompareSamplerate;
        CON_STANDARDCOMMENT     : NewSortMethod := AFCompareComment;
        CON_FILESIZE            : NewSortMethod := AFCompareFilesize;
        CON_FILEAGE             : NewSortMethod := AFCompareFileAge;
        CON_PFAD                : NewSortMethod := AFComparePath;
        CON_ORDNER              : NewSortMethod := AFCompareDirectory;
        CON_DATEINAME           : NewSortMethod := AFCompareFilename;
        CON_EXTENSION           : NewSortMethod := AFCompareExtension;
        CON_YEAR                : NewSortMethod := AFCompareYear;
        CON_GENRE               : NewSortMethod := AFCompareGenre;
        CON_LYRICSEXISTING      : NewSortMethod := AFCompareLyricsExists;
        CON_TRACKNR             : NewSortMethod := AFCompareTrackNr;
        CON_RATING              : NewSortMethod := AFCompareRating;
        CON_PLAYCOUNTER         : NewSortMethod := AFComparePlayCounter;
        CON_LASTFMTAGS          : NewSortMethod := AFCompareLastFMTagsExists;
        CON_CD                  : NewSortMethod := AFCompareCD;
        CON_FAVORITE            : NewSortMethod := AFCompareFavorite;
        CON_TRACKGAIN           : NewSortMethod := AFCompareTrackGain;
        CON_ALBUMGAIN           : NewSortMethod := AFCompareAlbumGain;
        CON_TRACKPEAK           : NewSortMethod := AFCompareTrackPeak;
        CON_ALBUMPEAK           : NewSortMethod := AFCompareAlbumPeak;
    else
        NewSortMethod := AFComparePath;
    end;

    if (TreeHeaderColumnTag = SortParams[0].Tag) and FlipSame then
    begin
        // wuppdi;
        // flip SortDirection of primary sorter
        case SortParams[0].Direction of
             sd_Ascending: SortParams[0].Direction := sd_Descending;
             sd_Descending: SortParams[0].Direction := sd_Ascending;
        end;
    end else
    begin
        // Set new primary sorter
        for i := SORT_MAX downto 1 do
        begin
            SortParams[i].Comparefunction := Sortparams[i-1].Comparefunction;
            SortParams[i].Direction := SortParams[i-1].Direction;
            SortParams[i].Tag := SortParams[i-1].Tag
        end;
        Sortparams[0].Comparefunction := NewSortmethod;
        Sortparams[0].Direction := sd_Ascending;
        Sortparams[0].Tag := TreeHeaderColumnTag;
    end;

end;
procedure TMedienBibliothek.AddStartJob(aJobtype: TJobType; aJobParam: String);
var newJob: TStartJob;
begin
    newJob := TStartJob.Create(aJobType, aJobParam);
    fJobList.Add(newJob);
end;

procedure TMedienBibliothek.ProcessNextStartJob;
var nextJob: TStartJob;
begin
    if (fJobList.Count > 0) AND (not CloseAfterUpdate) then
    begin
        nextJob := fJoblist[0];
        case nextJob.Typ of
          JOB_LoadLibrary:        ; // nothing to do
          JOB_AutoScanNewFiles    : PostMessage(MainWindowHandle, WM_MedienBib, MB_StartAutoScanDirs, 0) ;
          JOB_AutoScanMissingFiles: PostMessage(MainWindowHandle, WM_MedienBib, MB_StartAutoDeleteFiles, 0) ;
          JOB_StartWebServer      : PostMessage(MainWindowHandle, WM_MedienBib, MB_ActivateWebServer, 0) ;
          JOB_Finish              : begin
                // set the status to "free" (=0)
                SendMessage(MainWindowHandle, WM_MedienBib, MB_SetStatus, BIB_Status_Free);
                // if there are more jobs to do (should not happen) process the next jobs as well
                if fJobList.Count > 1 then
                    PostMessage(MainWindowHandle, WM_MedienBib, MB_CheckForStartJobs, 0);
                    // !!! do NOT use *SEND*message here
          end;
        end;
        fJoblist.Delete(0);
    end;
end;

procedure TMedienBibliothek.SortAnzeigeListe;
begin
  AnzeigeListe.Sort(MainSort);
  AnzeigeListIsCurrentlySorted := True;
end;

{
    --------------------------------------------------------
    CheckGenrePL
    CheckYearRange
    CheckRating
    CheckLength
    CheckTags
    - Helper for FillRandomList
    --------------------------------------------------------
}
//function TMedienBibliothek.CheckGenrePL(Genre: UnicodeString): Boolean;
//var GenreIDX: Integer;
//begin
  //if PlaylistFillOptions.SkipGenreCheck then
  //  result := true
  //else
  //begin
  //  GenreIDX := PlaylistFillOptions.GenreStrings.IndexOf(Genre);
  //  if GenreIDX > -1 then
  //    result := PlaylistFillOptions.GenreChecked[GenreIDX]
  //  else
  //    result := False; //PlaylistFillOptions.IncludeNAGenres; // Unbekannte genres auch aufz�hlen
  //end;
//end;

function TMedienBibliothek.CheckYearRange(Year: UnicodeString): Boolean;
var intYear: Integer;
begin
  result := False;
  if PlaylistFillOptions.SkipYearCheck then
    result := true
  else
  begin
    intYear := strtointdef(Year,-1);
    if (intYear >= PlaylistFillOptions.MinYear)
       AND (intYear <= PlaylistFillOptions.MaxYear) then
    result := True;
  end;
end;
function TMedienBibliothek.CheckRating(aRating: Byte): Boolean;
begin
    if aRating = 0 then arating := 128;
    Case PlaylistFillOptions.RatingMode of
        0: result := true;
        1: result := aRating >= PlaylistFillOptions.Rating;
        2: result := aRating = PlaylistFillOptions.Rating;
        3: result := aRating <= PlaylistFillOptions.Rating;
    else
        result := False;
    end;
end;
function TMedienBibliothek.CheckLength(aLength: Integer): Boolean;
begin
    result := ((Not PlaylistFillOptions.UseMinLength) or (aLength >= PlaylistFillOptions.MinLength))
            AND
             ((Not PlaylistFillOptions.UseMaxLength) or (aLength <= PlaylistFillOptions.MaxLength))
end;
function TMedienBibliothek.CheckTags(aTagList: TObjectList): Boolean;
var i, c: Integer;
begin
    if PlaylistFillOptions.SkipTagCheck or (not assigned(PlaylistFillOptions.WantedTags)) then
        result := true
    else
    begin
        c := 0;
        for i := 0 to PlaylistFillOptions.WantedTags.Count - 1 do
        begin
            if aTagList.IndexOf(PlaylistFillOptions.WantedTags[i]) >= 0 then
                inc(c);
        end;
        result := c >= PlaylistFillOptions.MinTagMatchCount;
    end;
end;

{
    --------------------------------------------------------
    FillRandomList
    - Generate a Random list from the library
    --------------------------------------------------------
}
procedure TMedienBibliothek.FillRandomList(aList: TAudioFileList);
var sourceList, tmpFileList: TAudioFileList;
    i: Integer;
    aAudioFile: TAudioFile;
begin
    EnterCriticalSection(CSUpdate);

    if PlaylistFillOptions.WholeBib then
        SourceList := Mp3ListePfadSort
    else
        SourceList := AnzeigeListe;

    // passende St�cke zusammensuchen
    tmpFileList := TAudioFileList.Create(False);
    try
        for i := 0 to SourceList.Count - 1 do
        begin
            aAudioFile := SourceList[i];
            if CheckYearRange(aAudioFile.Year)
                //and CheckGenrePL(aAudioFile.Genre)
                and CheckRating(aAudioFile.Rating)
                and CheckLength(aAudioFile.Duration)
                and CheckTags(aAudioFile.Taglist)
                then
              tmpFileList.Add(aAudioFile);
        end;
        // Liste mischen
        for i := 0 to tmpFileList.Count-1 do
            tmpFileList.Exchange(i,i + random(tmpFileList.Count-i));
        // �berfl�ssiges l�schen
        For i := tmpFileList.Count - 1 downto PlaylistFillOptions.MaxCount do
            tmpFileList.Delete(i);

        // eigentliche Zielliste mit Kopien f�llen
        for i := 0 to tmpFileList.Count-1 do
            tmpFileList[i].AddCopyToList(aList);
    finally
        tmpFileList.Free;
    end;

  LeaveCriticalSection(CSUpdate);
end;

procedure TMedienBibliothek.FillListWithMedialibrary(aList: TAudioFileList);
var sourceList: TAudioFileList;
    i: Integer;
begin
    EnterCriticalSection(CSUpdate);
    SourceList := Mp3ListePfadSort;
    for i := 0 to SourceList.Count - 1 do
        aList.Add(SourceList[i]);
    LeaveCriticalSection(CSUpdate);
end;

{
    --------------------------------------------------------
    ScanListContainsParentDir
    ScanListContainsSubDirs
    JobListContainsNewDirs
    - Helper for AutoScan-Lists
    --------------------------------------------------------
}
function TMedienBibliothek.ScanListContainsParentDir(NewDir: UnicodeString): UnicodeString;
var i: Integer;
begin
  result := '';
  for i := 0 to AutoScanDirList.Count - 1 do
  begin
    if AnsiStartsText(
        IncludeTrailingPathDelimiter(AutoScanDirList.Strings[i]), IncludeTrailingPathDelimiter(NewDir))  then
    begin
      result := AutoScanDirList.Strings[i];
      break;
    end;
  end;
end;
function TMedienBibliothek.ScanListContainsSubDirs(NewDir: UnicodeString): UnicodeString;
var i: Integer;
begin
  result := '';
  for i := AutoScanDirList.Count - 1 downto 0 do
  begin
    if AnsiStartsText(IncludeTrailingPathDelimiter(NewDir), IncludeTrailingPathDelimiter(AutoScanDirList.Strings[i]))  then
    begin
      result := result + #13#10 + AutoScanDirList.Strings[i];
      AutoScanDirList.Delete(i);
    end;
  end;
end;
Function TMedienBibliothek.JobListContainsNewDirs(aJobList: TStringList): Boolean;
var i: integer;
begin
  result := False;
  for i := 0 to aJobList.Count - 1 do
    if AutoScanDirList.IndexOf(IncludeTrailingPathDelimiter(aJobList.Strings[i])) = -1 then
    begin
      result := True;
      break;
    end;
end;

{
    --------------------------------------------------------
    ReSynchronizeDrives
    - Resync drives when new devices connects to the PC
    Note: This method runs in VCL-Thread.
       It MUST NOT be called when an update is running!
       If Windows send the message "New Drive" and an update is running,
       a counter will be increased, which is checked at the end of
       the update-process
    --------------------------------------------------------
}
function TMedienBibliothek.ReSynchronizeDrives: Boolean;
begin
    if Not TDriveManager.EnableUSBMode then
        result := false
    else
    begin
        EnterCriticalSection(CSAccessDriveList);
        fDriveManager.ReSynchronizeDrives;
        fPlaylistDriveManager.ReSynchronizeDrives;
        // relavant is only the "main" DriveManager later.
        // if a currently loaded PlaylistFile has changed: Just load it again by clicking it another time
        result := fDriveManager.DrivesHaveChanged;
        LeaveCriticalSection(CSAccessDriveList);
    end;
end;
{
    --------------------------------------------------------
    RepairDriveCharsAtAudioFiles
    RepairDriveCharsAtPlaylistFiles
    - Change all AudioFiles according to the new situation
    --------------------------------------------------------
}
procedure TMedienBibliothek.RepairDriveCharsAtAudioFiles;
begin
    EnterCriticalSection(CSAccessDriveList);
    fDrivemanager.RepairDriveCharsAtAudioFiles(Mp3ListePfadsort);
    LeaveCriticalSection(CSAccessDriveList);
    // am Ende die Pfadsort-Liste neu sortieren
    Mp3ListePfadsort.Sort(Sort_Pfad_asc);
end;
procedure TMedienBibliothek.RepairDriveCharsAtPlaylistFiles;
begin
    EnterCriticalSection(CSAccessDriveList);
    fDriveManager.RepairDriveCharsAtPlaylistFiles(AllPlaylistsPfadSort);
    LeaveCriticalSection(CSAccessDriveList);
    // am Ende die Pfadsort-Liste neu sortieren
    AllPlaylistsPfadSort.Sort(PlaylistSort_Name);
end;

{
    --------------------------------------------------------
    ExportFavorites
    ImportFavorites
    AddRadioStation
    - Managing webradio in the library
    --------------------------------------------------------
}
procedure TMedienBibliothek.ExportFavorites(aFilename: UnicodeString);
var fs: TMemoryStream;
    ini: TMemIniFile;
    i, c: Integer;
begin
    if AnsiLowerCase(ExtractFileExt(aFilename)) = '.pls' then
    begin
        //save as pls Playlist-File
        ini := TMeminiFile.Create(aFilename);
        try
            ini.Clear;
            for i := 0 to RadioStationList.Count - 1 do
            begin
                ini.WriteString ('playlist', 'File'  + IntToStr(i+1), TStation(RadioStationList[i]).URL);
                ini.WriteString ('playlist', 'Title'  + IntToStr(i+1), TStation(RadioStationList[i]).Name);
                ini.WriteInteger ('playlist', 'Length'  + IntToStr(i+1), -1);
            end;
            ini.WriteInteger('playlist', 'NumberOfEntries', RadioStationList.Count);
            ini.WriteInteger('playlist', 'Version', 2);
            try
                Ini.UpdateFile;
            except
                on E: Exception do
                    MessageDLG(E.Message, mtError, [mbOK], 0);
            end;
      finally
          ini.Free
      end;

    end
    else
    if AnsiLowerCase(ExtractFileExt(aFilename)) = '.nwl' then
    begin
        fs := TMemoryStream.Create;
        try
            c := RadioStationList.Count;
            fs.Write(c, SizeOf(c));
            for i := 0 to c-1 do
                TStation(RadioStationList[i]).SaveToStream(fs);
            try
                fs.SaveToFile(aFilename);
            except
                on E: Exception do MessageDLG(E.Message, mtError, [mbOK], 0);
            end;
        finally
            fs.Free;
        end;
    end;
end;
procedure TMedienBibliothek.ImportFavorites(aFilename: UnicodeString);
var fs: TMemoryStream;
    ini: TMemIniFile;
    NumberOfEntries, i: Integer;
    newURL, newName: String;
    NewStation: TStation;
begin
    if AnsiLowerCase(ExtractFileExt(aFilename)) = '.pls' then
    begin
        ini := TMeminiFile.Create(aFilename);
        try
            NumberOfEntries := ini.ReadInteger('playlist','NumberOfEntries',-1);
            for i := 1 to NumberOfEntries do
            begin
                newURL := ini.ReadString('playlist','File'+ IntToStr(i),'');
                if newURL = '' then continue;

                if GetAudioTypeFromFilename(newURL) = at_Stream then
                begin
                    NewStation := TStation.Create(MainWindowHandle);
                    NewStation.URL := newURL;
                    newName := ini.ReadString('playlist','Title'+ IntToStr(i),'');
                    NewStation.Name := NewName;
                    RadioStationList.Add(NewStation);
                end;
            end;
        finally
            ini.free;
        end;
    end else
    if AnsiLowerCase(ExtractFileExt(aFilename)) = '.nwl' then
    begin
        fs := TMemoryStream.Create;
        try
            fs.LoadFromFile(aFilename);
            fs.Position := 0;
            LoadRadioStationsFromStream_DEPRECATED(fs);
            Changed := True;
        finally
            fs.Free;
        end;
    end;
end;
{
    --------------------------------------------------------
    AddRadioStation
    Note: Station gets a new Handle for Messages here.
    --------------------------------------------------------
}
function TMedienBibliothek.AddRadioStation(aStation: TStation): Integer;
var newStation: TStation;
    i, maxIdx: Integer;

begin
    maxIdx := -1;
    for i := 0 to RadioStationList.Count - 1 do
        if TSTation(RadioStationList[i]).SortIndex > maxIdx  then
            maxIdx := TSTation(RadioStationList[i]).SortIndex;
    inc(maxIdx);

    newStation := TStation.Create(MainWindowHandle);
    newStation.Assign(aStation);
    newStation.SortIndex := maxIdx;
    RadioStationList.Add(NewStation);
    Changed := True;
    result := maxIdx;
end;

{
    --------------------------------------------------------
    SaveAsCSV
    - Save the library in a *.csv-File
    Note: Only Audiofiles are saved,
       No Playlists,
       No Webradio stations
    --------------------------------------------------------
}
function TMedienBibliothek.SaveAsCSV(aFilename: UnicodeString): boolean;
var i: integer;
  tmpStrList : TStringList;
begin
  if StatusBibUpdate >= 2 then
  begin
    result := False;
    exit;
  end;
  result := true;
  EnterCriticalSection(CSUpdate);
  tmpStrList := TStringList.Create;
  try
      tmpstrList.Capacity := Mp3ListeArtistSort.Count + 1;
      tmpstrList.Add('Artist;Title;Album;Genre;Year;Track;CD;Directory;Filename;Type;Filesize;Duration;Bitrate;vbr;Channelmode;Samplerate;Rating;Playcounter;Lyrics;TrackGain;AlbumGain;TrackPeak;AlbumPeak');
      for i:= 0 to Mp3ListeArtistSort.Count - 1 do
        tmpstrList.Add(Mp3ListeArtistSort[i].GenerateCSVString);
      try
          tmpStrList.SaveToFile(aFileName);
      except
          on E: Exception do
          begin
              MessageDLG(E.Message, mtError, [mbOK], 0);
              result := False;
          end;
      end;
  finally
      FreeAndNil(tmpStrList);
  end;
  LeaveCriticalSection(CSUpdate);
end;


{
    --------------------------------------------------------
    LoadDrivesFromStream
    SaveDrivesToStream
    - Read/Write a List of TDrives
    --------------------------------------------------------
}
function TMedienBibliothek.LoadDrivesFromStream_DEPRECATED(aStream: TStream): Boolean;
var SavedDriveList: TDriveList;
    DriveCount, i: Integer;
    newDrive: TDrive;
begin
    result := True;
    SavedDriveList := TDriveList.Create;
    try
        aStream.Read(DriveCount, SizeOf(Integer));
        for i := 0 to DriveCount - 1 do
        begin
            newDrive := TDrive.Create;
            newDrive.LoadFromStream_DEPRECATED(aStream);
            SavedDriveList.Add(newDrive);
        end;
        // Daten synchronisieren
        EnterCriticalSection(CSAccessDriveList);
            fDriveManager.SynchronizeDrives(SavedDriveList);
        LeaveCriticalSection(CSAccessDriveList);
        // SynchronizeDrives(SavedDriveList);
    finally
        SavedDriveList.Free;
    end;
end;

function TMedienBibliothek.LoadDrivesFromStream(aStream: TStream): Boolean;
var SavedDriveList: TDriveList;
begin
    result := True;
    EnterCriticalSection(CSAccessDriveList);
    SavedDriveList := TDriveList.Create(True);
    try
        fDriveManager.LoadDrivesFromStream(aStream, SavedDriveList);
        // we do not allow "add Library to Library", so we can just synch the Loaded Dirves into
        // the (empty) list of ManagedDrives there
        fDrivemanager.SynchronizeDrives(SavedDriveList);
    finally
        SavedDriveList.Free;
    end;
    LeaveCriticalSection(CSAccessDriveList);
end;


procedure TMedienBibliothek.SaveDrivesToStream(aStream: TStream);
var len: Integer;
    MainID: Byte;
    BytesWritten: LongInt;
    SizePosition, EndPosition: Int64;
begin
    MainID := 2;
    aStream.Write(MainID, SizeOf(Byte));
    len := 42; // dummy, needs to be corrected later
    SizePosition := aStream.Position;
    aStream.Write(len, SizeOf(Integer));

    // save the Drives from DriveManager into the Stream
    EnterCriticalSection(CSAccessDriveList);
    fDriveManager.SaveDrivesToStream(aStream);
    LeaveCriticalSection(CSAccessDriveList);

    // correct the size information for this block
    EndPosition := aStream.Position;
    aStream.Position := SizePosition;

    BytesWritten := EndPosition - SizePosition;
    aStream.Write(BytesWritten, SizeOf(BytesWritten));
    // seek to the end position again
    aStream.Position := EndPosition;
end;
{
    --------------------------------------------------------
    LoadAudioFilesFromStream
    SaveAudioFilesToStream
    - Read/Write a List of TAudioFiles
    --------------------------------------------------------
}
function TMedienBibliothek.LoadAudioFilesFromStream(aStream: TStream): Boolean;
var FilesCount, i: Integer;
    newAudioFile: TAudioFile;
begin
    result := True;

    aStream.Read(FilesCount, SizeOf(FilesCount));
    for i := 1 to FilesCount do
    begin
        // create a new Audiofile object and read the data from the stream
        newAudioFile := TAudioFile.Create;
        newAudioFile.LoadDataFromStream(aStream, False, True);
        // add the file to the update list
        UpdateList.Add(newAudioFile);
    end;

    // adjust paths of the AudioFiles. Needs to be done in VCL-Thread due to Relative Paths
    SendMessage(MainWindowHandle, WM_MedienBib, MB_FixAudioFilePaths, 0);
end;

procedure TMedienBibliothek.ProcessLoadedFilenames;
var i: Integer;
    newAudioFile: TAudioFile;
    currentDriveID: Integer;
    CurrentDriveChar: Char;
begin
    EnterCriticalSection(CSAccessDriveList);

    CurrentDriveChar := ' ';
    currentDriveID := -2;

    for i := 0 to UpdateList.Count-1 do
    begin
        newAudioFile := UpdateList[i];
        if newAudioFile.AudioType = at_File then
            newAudioFile.Pfad := ExpandFilename(newAudioFile.Pfad);

        ///  New method since version 4.14
        ///  Nemp will save only relative Paths, if LibrayrFile and AudioFile are on the same
        ///  Drive.
        ///  If USBMode is enabled, and the loaded PlaylistFile wasn't stored as a relative Path: DO adjust Drive letter
        ///  Otherwise: DO NOT adjust the Drive Letter
        if TDriveManager.EnableUSBMode and (newAudioFile.DriveID <> -5) then
        begin
            // now assign a proper drive letter, according to the DriveID of the audiofile
            if currentDriveID <> newAudioFile.DriveID then
            begin
                // currentDriveChar does not match, we need to find the correct one
                if newAudioFile.DriveID <= -1 then
                    CurrentDriveChar := '\'
                else
                begin
                    if newAudioFile.DriveID < fDriveManager.ManagedDrivesCount then
                        CurrentDriveChar := fDriveManager.GetManagedDriveByIndex(newAudioFile.DriveID).Drive[1]
                end;
                // anyway, we've got a new ID here, and we can set the next drive with this ID faster
                currentDriveID := newAudioFile.DriveID;
            end;
            // now *actually* assign the proper drive letter ;-)
            newAudioFile.SetNewDriveChar(CurrentDriveChar);
        end;
    end;

    LeaveCriticalSection(CSAccessDriveList);
end;

function TMedienBibliothek.LoadAudioFilesFromStream_DEPRECATED(aStream: TStream; MaxSize: Integer): Boolean;
var FilesCount, i, DriveID: Integer;
    newAudioFile: TAudioFile;
    ID: Byte;
    CurrentDriveChar: WideChar;

begin
    EnterCriticalSection(CSAccessDriveList);

    result := True;
    CurrentDriveChar := 'C';
    aStream.Read(FilesCount, SizeOf(FilesCount));

    for i := 1 to FilesCount do
    begin
        aStream.Read(ID, SizeOf(ID));
        case ID of
            0: begin
                newAudioFile := TAudioFile.Create;
                {audioSize := }newAudioFile.LoadSizeInfoFromStream_DEPRECATED(aStream);
                newAudioFile.LoadDataFromStream_DEPRECATED(aStream);
                newAudioFile.SetNewDriveChar(CurrentDriveChar);
                UpdateList.Add(newAudioFile);
            end;
            1: begin
                // LaufwerksID lesen, diese suchen, LW-Buchstaben auslesen.
                aStream.Read(DriveID, SizeOf(DriveID));
                // DriveID ist der index des Laufwerks in der fDrives-Liste
                if DriveID < fDriveManager.ManagedDrivesCount then  // fUsedDrives.Count then
                begin
                    aStream.Read(ID, SizeOf(ID));  // this  ID=0 is just the marker as ID=0 used in this CASE-loop
                    if ID <> 0 then
                    begin
                        SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                                    Integer(PWideChar(_(Medialibrary_InvalidLibFile) +
                                        #13#10 + 'invalid audiofile data' +
                                        #13#10 + 'DriveID: ID <> 0' )));
                        result := False;
                        LeaveCriticalSection(CSAccessDriveList);
                        exit;
                    end;
                    if DriveID = -1 then
                        CurrentDriveChar := '\'
                    else
                        CurrentDriveChar := fDriveManager.GetManagedDriveByIndex(DriveID).Drive[1];
                        // CurrentDriveChar := WideChar(TDrive(fUsedDrives[DriveID]).Drive[1]);
                    newAudioFile := TAudioFile.Create;

                    {audioSize := }newAudioFile.LoadSizeInfoFromStream_DEPRECATED(aStream);
                    newAudioFile.LoadDataFromStream_DEPRECATED(aStream);
                    newAudioFile.SetNewDriveChar(CurrentDriveChar);
                    UpdateList.Add(newAudioFile);
                end else
                begin
                    SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                                    Integer(PWideChar(_(Medialibrary_InvalidLibFile) +
                                        #13#10 + 'invalid audiofile data' +
                                        #13#10 + 'invalid DriveID')));
                    result := False;
                    LeaveCriticalSection(CSAccessDriveList);
                    exit;
                end;
            end;
        else
            SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                    Integer(PWideChar(_(Medialibrary_InvalidLibFile) +
                        #13#10 + 'invalid audiofile data' +
                        #13#10 + 'invalid ID' + IntToStr(ID))));
            result := False;
            LeaveCriticalSection(CSAccessDriveList);
            exit;
        end;
    end;

    LeaveCriticalSection(CSAccessDriveList);
end;


procedure TMedienBibliothek.SaveAudioFilesToStream(aStream: TStream; StreamFilename: String);
var i, len: Integer;
    CurrentDriveChar: WideChar;
    aAudioFile: TAudioFile;
    aDrive: tDrive;
    MainID: Byte;
    FileCount, currentDriveID: Integer;
    BytesWritten: LongInt;
    SizePosition, EndPosition: Int64;
    ERROROCCURRED, DoMessageShow: Boolean;
    LibrarySaveDriveChar: Char;
    AudioFileSavePath: String;

begin
    EnterCriticalSection(CSAccessDriveList);

    // write size info before writing actual data
    MainID := 1;
    aStream.Write(MainID, SizeOf(MainID));
    len := 42; // just a dummy value here. needs to be corrected at the end of this procedure
    SizePosition := aStream.Position;
    aStream.Write(len, SizeOf(len));

    FileCount := Mp3ListePfadSort.Count; // * FAKE_FILES_MULTIPLIER;

    BytesWritten := aStream.Write(FileCount, sizeOf(FileCount));
    CurrentDriveChar := '-';
    currentDriveID := -2;
    // if Length(StreamFilename) > 0 then
    LibrarySaveDriveChar := StreamFilename[1];
    // when we save it on a network drive: Don't use relative paths at all
    if LibrarySaveDriveChar = '\' then
        LibrarySaveDriveChar := '-';

    DoMessageShow := True;

    ///  New saving method since Nemp 4.14
    ///  (1) If an AudioFile is on the same local Drive than the LibraryFile (parameter StreamFilename),
    ///      then we save the RELATIVE path to the AudioFile. In that case, we also use an invalid DriveID
    ///      for it, as the LoadFromStream method MUST NOT "fix" the Drive Letter later.
    ///      (Possible situation: Nemp with the complete music collection is moved to another computer, on
    ///       a different drive with a different ID, into a different base directory)
    ///  (2) If the Audiofiles are on a different Drive, then we use the previous system with "DriveID"
    ///      (= index of the Drive in the DriveList), so that Nemp can fix the DriveLetter after loading.
    ///      Possible situation for this: External HardDrive with more than one partition used for the
    ///      music collection

    for i := 0 to Mp3ListePfadSort.Count - 1 do
    begin
        ERROROCCURRED := False;
        aAudioFile := MP3ListePfadSort[i];

        if (aAudioFile.Ordner[1] = LibrarySaveDriveChar) and TDrivemanager.EnableCloudMode then
        begin
            aAudioFile.DriveID := -5;
            AudioFileSavePath := ExtractRelativePath(StreamFilename, aAudioFile.Pfad );
        end else
        begin
              // get a Proper DriveID, if the Drive char is different from the previouos file
              if aAudioFile.Ordner[1] <> CurrentDriveChar then
              begin
                  if aAudioFile.Ordner[1] <> '\' then
                  begin
                      // Neues Laufwerk - Infos dazwischenschieben
                      aDrive := fDriveManager.GetManagedDriveByChar(aAudioFile.Ordner[1]);
                              // GetDriveFromListByChar(fUsedDrives, Char(aAudioFile.Ordner[1]));
                      if assigned(aDrive) then
                      begin
                          currentDriveID := aDrive.ID;
                          CurrentDriveChar := aAudioFile.Ordner[1];
                      end else
                      begin
                          if DoMessageShow then
                              MessageDLG((Medialibrary_SaveException1), mtError, [MBOK], 0);
                          DoMessageShow := False;
                          ERROROCCURRED := True;
                      end;
                  end else
                  begin
                      currentDriveID := -1;
                      CurrentDriveChar := aAudioFile.Ordner[1];
                  end;
              end;
              // set the DriveID properly
              aAudioFile.DriveID := currentDriveID;
              AudioFileSavePath := aAudioFile.Pfad;
        end;
        // write the audiofile data into the stream
        if not ERROROCCURRED then
            BytesWritten := BytesWritten + aAudioFile.SaveToStream(aStream, AudioFileSavePath);

    end;

    // correct the size information for this block
    EndPosition := aStream.Position;
    aStream.Position := SizePosition;
    aStream.Write(BytesWritten, SizeOf(BytesWritten));
    // seek to the end position again
    aStream.Position := EndPosition;

    LeaveCriticalSection(CSAccessDriveList);
end;

{
    --------------------------------------------------------
    LoadPlaylistsFromStream
    SavePlaylistsToStream
    - Read/Write a List of Playlist-Files (TJustaStrings)
    --------------------------------------------------------
}
function TMedienBibliothek.LoadPlaylistsFromStream(aStream: TStream): Boolean;
var i, FileCount: Integer;
    NewLibraryPlaylist: TLibraryPlaylist;
begin
    result := True;
    aStream.Read(FileCount, SizeOf(FileCount));
        for i := 1 to FileCount do
        begin
            NewLibraryPlaylist := TLibraryPlaylist.Create;
            NewLibraryPlaylist.LoadFromStream(aStream);
            PlaylistUpdateList_Playlist.Add(NewLibraryPlaylist);
        end;
        // fix Paths for the Playlists. Needs to be done in VCL-Thread due to Relative Paths
        SendMessage(MainWindowHandle, WM_MedienBib, MB_FixPlaylistFilePaths, 0);
end;

procedure TMedienBibliothek.ProcessLoadedPlaylists;
var i, currentDriveID: Integer;
    CurrentDriveChar: WideChar;
    jas: TJustaString;

    NewLibraryPlaylist: TLibraryPlaylist;
begin
    EnterCriticalSection(CSAccessDriveList);

    CurrentDriveChar := ' ';
    currentDriveID := -2;

    for i := 1 to PlaylistUpdateList_Playlist.Count-1 do
    begin
        NewLibraryPlaylist := TLibraryPlaylist(PlaylistUpdateList_Playlist[i]);
        NewLibraryPlaylist.Path := ExpandFilename(NewLibraryPlaylist.Path);

        // if USBMode is enabled, and the loaded PlaylistFile wasn't stored as a relative Path:
        // adjust Drive letter
        if TDriveManager.EnableUSBMode and (NewLibraryPlaylist.DriveID <> -5) then
        begin
              if currentDriveID <> NewLibraryPlaylist.DriveID then
              begin
                  // currentDriveChar does not match, we need to find the correct one
                  if NewLibraryPlaylist.DriveID <= -1 then
                      CurrentDriveChar := '\'
                  else
                  begin
                      if NewLibraryPlaylist.DriveID < fDriveManager.ManagedDrivesCount then
                          CurrentDriveChar := fDriveManager.GetManagedDriveByIndex(NewLibraryPlaylist.DriveID).Drive[1];
                  end;
                  // anyway, we've got a new ID here, and we can set the next drive with this ID faster
                  currentDriveID := NewLibraryPlaylist.DriveID;
              end;
              // set the proper drive char
              NewLibraryPlaylist.SetNewDriveChar(CurrentDriveChar);
        end;
        // add a new item for the list of Playlists
        jas := TJustaString.create(NewLibraryPlaylist.Path, ExtractFileName(NewLibraryPlaylist.Path));
        PlaylistUpdateList.Add(jas);
    end;

    // clear the list of LibraryPlaylist-Objects. We do not need them any longer.
    PlaylistUpdateList_Playlist.Clear;

    LeaveCriticalSection(CSAccessDriveList);
end;

function TMedienBibliothek.LoadPlaylistsFromStream_DEPRECATED(aStream: TStream): Boolean;
var FilesCount, i, DriveID: Integer;
    jas: TJustaString;
    ID: Byte;
    CurrentDriveChar: WideChar;
    tmputf8: UTF8String;
    tmpWs: UnicodeString;
    len: Integer;
begin
    EnterCriticalSection(CSAccessDriveList);

    result := True;
    CurrentDriveChar := 'C';
    aStream.Read(FilesCount, SizeOf(FilesCount));
    for i := 1 to FilesCount do
    begin
        aStream.Read(ID, SizeOf(ID));
        case ID of
            0: begin
                aStream.Read(len,sizeof(len));
                setlength(tmputf8, len);
                aStream.Read(PAnsiChar(tmputf8)^,len);
                tmpWs := UTF8ToString(tmputf8);
                tmpWs[1] := CurrentDriveChar;

                jas := TJustaString.create(tmpWs, ExtractFileName(tmpWs));
                PlaylistUpdateList.Add(jas);
            end;
            1: begin
                // LaufwerksID lesen, diese suchen, LW-Buchstaben auslesen.
                aStream.Read(DriveID, SizeOf(DriveID));
                // DriveID ist der index des Laufwerks in der fDrives-Liste
                if DriveID < fDriveManager.ManagedDrivesCount then
                      // fUsedDrives.Count then
                begin
                    aStream.Read(ID, SizeOf(ID));
                    if ID <> 0 then
                    begin
                        //MessageDLG((Medialibrary_InvalidLibFile + #13#10 + 'DriveID falsch: ID <> 0'), mtError, [MBOK], 0);
                        SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                                    Integer(PWideChar(_(Medialibrary_InvalidLibFile) +
                                        #13#10 + 'invalid playlist data' +
                                        #13#10 + 'DriveID: ID <> 0' )));
                        result := False;
                        LeaveCriticalSection(CSAccessDriveList);
                        exit;
                    end;
                    if DriveID = -1 then
                        CurrentDriveChar := '\'
                    else
                        CurrentDriveChar := fDriveManager.GetManagedDriveByIndex(DriveID).Drive[1];
                                // WideChar(TDrive(fUsedDrives[DriveID]).Drive[1]);
                    aStream.Read(len,sizeof(len));
                    setlength(tmputf8, len);
                    aStream.Read(PAnsiChar(tmputf8)^,len);
                    tmpWs := UTF8ToString(tmputf8);
                    tmpWs[1] := CurrentDriveChar;

                    jas := TJustaString.create(tmpWs, ExtractFileName(tmpWs));
                    PlaylistUpdateList.Add(jas);
                end else
                begin
                    //MessageDLG((Medialibrary_InvalidLibFile + #13#10 + 'DriveID falsch: ' + IntToStr(DriveID)), mtError, [MBOK], 0);
                    SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                                    Integer(PWideChar(_(Medialibrary_InvalidLibFile) +
                                        #13#10 + 'invalid playlist data' +
                                        #13#10 + 'invalid DriveID' )));
                    result := False;
                    LeaveCriticalSection(CSAccessDriveList);
                    exit;
                end;
            end;
        else
            //MessageDLG((Medialibrary_InvalidLibFile + #13#10 + 'ID falsch: ' + inttostr(ID)), mtError, [MBOK], 0);
            SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                            Integer(PWideChar(_(Medialibrary_InvalidLibFile) +
                                #13#10 + 'invalid playlist data' +
                                #13#10 + 'invalid ID' )));
            result := False;
            LeaveCriticalSection(CSAccessDriveList);
            exit;
        end;
    end;
    LeaveCriticalSection(CSAccessDriveList);
end;
procedure TMedienBibliothek.SavePlaylistsToStream(aStream: TStream; StreamFilename: String);
var i, len, FileCount: Integer;
    jas: TJustaString;
    aDrive: TDrive;
    MainID: Byte;
    BytesWritten: LongInt;
    SizePosition, EndPosition: Int64;
    NewLibraryPlaylist: TLibraryPlaylist;

    LibrarySaveDriveChar: Char;
begin
    EnterCriticalSection(CSAccessDriveList);

    // write block header, with dummy size (write the correct value at the end of this procedure)
    MainID := 3;
    aStream.Write(MainID, SizeOf(MainID));
    len := 42; // dummy size;
    SizePosition := aStream.Position;
    aStream.Write(len, SizeOf(len));

    // write FileCount
    FileCount := AllPlaylistsPfadSort.Count;
    BytesWritten := aStream.Write(FileCount, sizeOf(FileCount));

    LibrarySaveDriveChar := StreamFilename[1];
    // when we save it on a network drive: Don't use relative paths at all
    if LibrarySaveDriveChar = '\' then
        LibrarySaveDriveChar := '-';

    //----------------------------
    // write the actual data
    NewLibraryPlaylist := TLibraryPlaylist.Create;
    try
        for i := 0 to AllPlaylistsPfadSort.Count - 1 do
        begin
            jas := TJustaString(AllPlaylistsPfadSort[i]);

            if (jas.DataString[1] = LibrarySaveDriveChar) and TDrivemanager.EnableCloudMode then
            begin
                // write Relative Path
                NewLibraryPlaylist.DriveID := -5;
                NewLibraryPlaylist.Path := ExtractRelativePath(StreamFilename, jas.DataString);
            end else
            begin
                // write absolute Path
                NewLibraryPlaylist.Path := jas.DataString;
                if jas.DataString[1] = '\' then
                    NewLibraryPlaylist.DriveID := -1
                else
                begin
                    aDrive := fDriveManager.GetManagedDriveByChar(jas.DataString[1]);
                    if assigned(aDrive) then
                        NewLibraryPlaylist.DriveID := aDrive.ID
                    else
                    begin
                        //MessageDLG((Medialibrary_SaveException1), mtError, [MBOK], 0);


                        //MessageDLG( 'unbekannte DriveID f�r ' +  jas.DataString, mtError, [MBOK], 0);
                        //LeaveCriticalSection(CSAccessDriveList);
                        //exit;
                    end;
                end;
            end;

            BytesWritten := BytesWritten + NewLibraryPlaylist.SaveToStream(aStream);
        end;
    finally
        NewLibraryPlaylist.Free;
    end;
    // --------------------------
    // write correct block size
    EndPosition := aStream.Position;
    aStream.Position := SizePosition;
    aStream.Write(BytesWritten, SizeOf(BytesWritten));
    // seek to the end position again
    aStream.Position := EndPosition;

    LeaveCriticalSection(CSAccessDriveList);
end;
{
    --------------------------------------------------------
    LoadRadioStationsFromStream
    SaveRadioStationsToStream
    - Read/Write a List of Webradio stations
    --------------------------------------------------------
}
function TMedienBibliothek.LoadRadioStationsFromStream(aStream: TStream): Boolean;
var i, StationCount: Integer;
    NewStation: TStation;
begin
    // todo: Some error handling?
    Result := True;

    aStream.Read(StationCount, SizeOf(StationCount));
    // Stationen laden
    for i := 1 to StationCount do
    begin
        NewStation := TStation.Create(MainWindowHandle);
        NewStation.LoadFromStream(aStream);
        RadioStationList.Add(NewStation);
    end;
end;

function TMedienBibliothek.LoadRadioStationsFromStream_DEPRECATED(aStream: TStream): Boolean;
var i, c: Integer;
    NewStation: TStation;
begin
    // todo: Some error handling?
    Result := True;

    aStream.Read(c, SizeOf(c));
    // Stationen laden
    for i := 1 to c do
    begin
        NewStation := TStation.Create(MainWindowHandle);
        NewStation.LoadFromStream_DEPRECATED(aStream);
        RadioStationList.Add(NewStation);
    end;
end;

procedure TMedienBibliothek.SaveRadioStationsToStream(aStream: TStream);
var i, c, len: Integer;
    MainID: Byte;
    BytesWritten: LongInt;
    SizePosition, EndPosition: Int64;
begin
    MainID := 4;
    aStream.Write(MainID, SizeOf(MainID));
    len := 42; // just a dummy value here. needs to be corrected at the end of this procedure
    SizePosition := aStream.Position;
    aStream.Write(len, SizeOf(len));

    c := RadioStationList.Count;
    aStream.Write(c, SizeOf(c));
    // speichern
    for i := 0 to c-1 do
        TStation(RadioStationList[i]).SaveToStream(aStream);

    // correct the size information for this block
    EndPosition := aStream.Position;
    aStream.Position := SizePosition;
    BytesWritten := EndPosition - SizePosition;
    aStream.Write(BytesWritten, SizeOf(BytesWritten));
    // seek to the end position again
    aStream.Position := EndPosition;
end;

{
    --------------------------------------------------------
    LoadFromFile4
    - Load a gmp-File in Nemp 3.3-Format

    - Subversion: 0,1: load the blocks completely
                    2: buffing possible for audiofiles
    --------------------------------------------------------
}
procedure TMedienBibliothek.LoadFromFile4(aStream: TStream; SubVersion: Integer);
var MainID: Byte;
    BlockSize: Integer;
    GoOn: Boolean;
begin
    // neues Format besteht aus mehreren "Bl�cken"
    // Jeder Block beginnt mit einer ID (1 Byte)
    //             und einer Gr��enangabe (4 Bytes)
    // Die einzelnen Bl�cke werden getrennt geladen und gespeichert
    // wichtig: Zuerst die Laufwerks-Liste in die Datei speichern,
    // DANACH die Audiodateien
    // Denn: In der Audioliste wird Bezug auf die UsedDrives genommen!!
    GoOn := True;

    While (aStream.Position < aStream.Size) and GoOn do
    begin
        aStream.Read(MainID, SizeOf(Byte));
        aStream.Read(BlockSize, SizeOf(Integer));

        case MainID of
            // note: Drives are located BEFORE the Audiofiles in the *.gmp-File!
            1: GoOn := LoadAudioFilesFromStream_DEPRECATED(aStream, BlockSize); // Audiodaten lesen
            2: GoOn := LoadDrivesFromStream_DEPRECATED(aStream); // Drive-Info lesen
            3: GoOn := LoadPlaylistsFromStream_DEPRECATED(aStream);
            4: GoOn := LoadRadioStationsFromStream_DEPRECATED(aStream);
        else
          aStream.Seek(BlockSize, soFromCurrent);
        end;
    end;
end;


procedure TMedienBibliothek.LoadFromFile5(aStream: TStream; SubVersion: Integer);
var MainID: Byte;
    BlockSize: Integer;
    GoOn: Boolean;
begin
    // Changes in Version 5:
    // - the structure of the different blocks has been unified
    // - the content of the blocks (e.g. audiofiles) is kinda update-proof.
    //   It is easier to add new data fields without changing the file format
    // - also some simplifications (but at the cost of a minor increase of size)
    GoOn := True;

    While (aStream.Position < aStream.Size) and GoOn do
    begin
        aStream.Read(MainID, SizeOf(Byte));
        aStream.Read(BlockSize, SizeOf(Integer));

        case MainID of
            // note: Drives are located BEFORE the Audiofiles in the *.gmp-File!
            1: GoOn := LoadAudioFilesFromStream(aStream);   // 4.13: Done
            2: GoOn := LoadDrivesFromStream(aStream);       // 4.13: Done
            3: GoOn := LoadPlaylistsFromStream(aStream);    // 4.13: Done
            4: GoOn := LoadRadioStationsFromStream(aStream); // 4.13: done
        else
          aStream.Seek(BlockSize, soFromCurrent);
        end;
    end;
end;

{
    --------------------------------------------------------
    LoadFromFile
    - Load a gmp-File
    --------------------------------------------------------
}
procedure TMedienBibliothek.LoadFromFile(aFilename: UnicodeString; Threaded: Boolean = False);
var Dummy: Cardinal;
begin
    StatusBibUpdate := 2;
    SendMessage(MainWindowHandle, WM_MedienBib, MB_BlockWriteAccess, 0);
    // Nemp 4.14: We may use relative Paths in the Library as well
    SetCurrentDir(ExtractFilePath(aFileName));
    if Threaded then
    begin
        fBibFilename := aFilename;
        fHND_LoadThread := (BeginThread(Nil, 0, @fLoadLibrary, Self, 0, Dummy));
    end else
        fLoadFromFile(aFilename);
end;

Procedure fLoadLibrary(MB: TMedienbibliothek);
begin
    MB.fLoadFromFile(MB.fBibFilename);
    try
      CloseHandle(MB.fHND_LoadThread);
    except
    end;
end;

procedure TMedienBibliothek.fLoadFromFile(aFilename: UnicodeString);
var aStream: TFastFileStream;
    Header: AnsiString;
    version, Subversion: byte;
    success: Boolean;
begin
    // if StatusBibUpdate <> 0 then exit;

    success := True; // think positive!
    if FileExists(aFilename) then
    begin
        try
            aStream := TFastFileStream.Create(aFilename, fmOpenRead or fmShareDenyWrite);
            try
                aStream.BufferSize := BUFFER_SIZE;

                setlength(Header,length(MP3DB_HEADER));
                aStream.Read(Header[1],length(MP3DB_HEADER));
                aStream.Read(Version,sizeOf(MP3DB_VERSION));
                aStream.Read(Subversion, sizeof(MP3DB_SUBVERSION));

                if Header = 'GMP' then
                begin
                    case Version of
                        2,
                        3: begin
                            SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                                    Integer(PWideChar(_(Medialibrary_LibFileTooOld) )));

                            success := False;
                        end;
                        4: begin
                            if Subversion <= 2 then // new in Nemp 4.0: Subversion changed to 1
                                                    // (additional value in RadioStations)
                            begin
                                EnterCriticalSection(CSAccessDriveList);
                                LoadFromFile4(aStream, Subversion);
                                LeaveCriticalSection(CSAccessDriveList);
                                NewFilesUpdateBib(True);
                            end else
                            begin
                                SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                                    Integer(PWideChar(_(Medialibrary_LibFileTooYoung) )));
                                success := False;
                            end;
                        end;
                        5: begin
                            // new format since Nemp 4.13, end of 2019
                            if subversion <= 1 then
                            begin
                                // EnterCriticalSection(CSAccessDriveList);
                                LoadFromFile5(aStream, Subversion);
                                // LeaveCriticalSection(CSAccessDriveList);
                                NewFilesUpdateBib(True);
                            end else
                            begin
                                SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                                    Integer(PWideChar(_(Medialibrary_LibFileTooYoung) )));
                                success := False;
                            end;
                        end
                        else
                        begin
                            SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                                Integer(PWideChar(_(Medialibrary_LibFileTooYoung) )));
                            success := False;
                        end;

                    end; // case Version

                    if RadioStationList.Count = 0 then
                    begin
                        if FileExists(ExtractFilePath(ParamStr(0)) + 'Data\default.nwl') then
                            ImportFavorites(ExtractFilePath(ParamStr(0)) + 'Data\default.nwl')
                        else
                            if FileExists(SavePath + 'default.nwl') then
                                ImportFavorites(SavePath + 'default.nwl')
                    end;
                end else // if Header = 'GMP'
                begin
                    SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                            Integer(PWideChar(_(Medialibrary_InvalidLibFile) )));
                    success := False;
                end;

                if Not Success then
                    // We have no valid library, but we have to update anyway,
                    // as this ensures AutoScan and/or webserver-activation
                    NewFilesUpdateBib(True);
            finally
                FreeAndNil(aStream);
            end;
        except
            on E: Exception do begin
                SendMessage(MainWindowHandle, WM_MedienBib, MB_InvalidGMPFile,
                        Integer(PWideChar((ErrorLoadingMediaLib) + #13#10 + E.Message )));
                // success := False;
            end;
        end;
    end else
    begin
        // Datei nicht vorhanden - nur Webradio laden
        if FileExists(ExtractFilePath(ParamStr(0)) + 'Data\default.nwl') then
            ImportFavorites(ExtractFilePath(ParamStr(0)) + 'Data\default.nwl')
        else
            if FileExists(SavePath + 'default.nwl') then
                ImportFavorites(SavePath + 'default.nwl');

        // We have no library, but we have to update anyway,
        // as this ensures AutoScan and/or webserver-activation
        NewFilesUpdateBib(True);

    end;
end;

{
    --------------------------------------------------------
    SaveToFile
    - Save a gmp-File
    --------------------------------------------------------
}
procedure TMedienBibliothek.SaveToFile(aFilename: UnicodeString; Silent: Boolean = True);
var  str: TFastFileStream;
    aFile: THandle;
begin
  if not FileExists(aFilename) then
  begin
      aFile := FileCreate(aFileName);
      if aFile = INVALID_HANDLE_VALUE then
          raise EFCreateError.CreateResFmt(@SFCreateErrorEx, [ExpandFileName(AFileName), SysErrorMessage(GetLastError)])
      else
          CloseHandle(aFile);
  end;

  try
      Str := TFastFileStream.Create(aFileName, fmCreate or fmOpenReadWrite);
      try
        EnterCriticalSection(CSAccessDriveList);

        str.Write(AnsiString(MP3DB_HEADER), length(MP3DB_HEADER));
        str.Write(MP3DB_VERSION,sizeOf(MP3DB_VERSION));
        str.Write(MP3DB_SUBVERSION, sizeof(MP3DB_SUBVERSION));

        SaveDrivesToStream(str); // 4.13: Done

        SaveAudioFilesToStream(str, aFileName);
        SavePlaylistsToStream(str, aFileName);
        SaveRadioStationsToStream(str);
        str.Size := str.Position;
      finally
        LeaveCriticalSection(CSAccessDriveList);
        FreeAndNil(str);
      end;
      Changed := False;
  except
      on e: Exception do
          //if not Silent then
              MessageDLG(E.Message, mtError, [MBOK], 0)
  end;
end;

{function TMedienBibliothek.GetDriveFromUsedDrives(aChar: Char): TDrive;
begin
    result := GetDriveFromListByChar(fUsedDrives, aChar);
end;
}


// this function should only be called after a check for StatusBibUpdate
// (used in the warning messageDlg when the User deactivates Lyrics usage)
function TMedienBibliothek.GetLyricsUsage: TLibraryLyricsUsage;
var i: Integer;
    aAudioFile: TAudioFile;
begin
    result.TotalFiles := Mp3ListePfadSort.Count;
    result.FilesWithLyrics := 0;
    result.TotalLyricSize := 0;

    if StatusBibUpdate >= 2 then exit;
    EnterCriticalSection(CSUpdate);
    for i := 0 to Mp3ListePfadSort.Count - 1 do
    begin
        aAudioFile := Mp3ListePfadSort[i];
        if aAudioFile.LyricsExisting then
        begin
            inc(result.FilesWithLyrics);
            inc(result.TotalLyricSize, Length(aAudioFile.Lyrics));
        end;
    end;

    if BibSearcher.AccelerateLyricSearch then
        result.TotalLyricSize := result.TotalLyricSize * 2;

    LeaveCriticalSection(CSUpdate);
end;

procedure TMedienBibliothek.RemoveAllLyrics;
var i: Integer;
begin
    if StatusBibUpdate >= 2 then exit;

    EnterCriticalSection(CSUpdate);
    for i := 0 to Mp3ListePfadSort.Count - 1 do
        Mp3ListePfadSort[i].Lyrics := '';

    BibSearcher.ClearTotalLyricString;
    LeaveCriticalSection(CSUpdate);
end;




initialization

  InitializeCriticalSection(CSUpdate);
  InitializeCriticalSection(CSAccessDriveList);
  InitializeCriticalSection(CSAccessBackupCoverList);
  InitializeCriticalSection(CSLyricPriorities);

finalization

  DeleteCriticalSection(CSUpdate);
  DeleteCriticalSection(CSAccessDriveList);
  DeleteCriticalSection(CSAccessBackupCoverList);
  DeleteCriticalSection(CSLyricPriorities);
end.

