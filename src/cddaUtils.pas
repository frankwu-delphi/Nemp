unit cddaUtils;

interface

uses  Windows, Forms, Messages, SysUtils, Variants, ContNrs, Classes, StrUtils,
      bass, basscd, CDSelection, Controls, dialogs

      ;

const MAXDRIVES = 10;  // maximum number auf CDDA-Drives

type
    TCddaError = (cddaErr_None,
                  cddaErr_invalidPath,
                  cddaErr_invalidDrive,
                  cddaErr_invalidTrackNumber,
                  cddaErr_DriveNotReady,
                  cddaErr_NoAudioTrack,
                  cddaErr_Unknown
                  );

    TCDDADrive = class
        private
            fCachedCddbData: AnsiString;
            fCachedCddbID  : AnsiString;
            fIndex         : Integer;
            fIsCompilation : Boolean;
            fDelimter      : Char;
        public
            Vendor   : AnsiString;
            Product  : AnsiString;
            Revision : AnsiString;
            Letter   : Char;

            procedure Assign(aDrive: TCDDADrive);
            function GetCDDBData(CheckOnline: Boolean): AnsiString;
            procedure CheckForCompilation(aData: AnsiString);
    end;

    TCDDAFile = class
        private
            fTitle    : String;
            fArtist   : String;
            fAlbum    : String;
            fDuration : Integer;
            fTrack    : Integer;
            fYear     : String;
            fGenre    : String;
            fCddbID   : String;

            fDriveLetter : Char;
            fDriveNumber : Integer;

            function fGetDriveChar(aPath: String): Char;
            function fGetDriveNumber(aDriveChar: Char): Integer;

            function fGetTrackNumber(aPath: String): Integer;

            function fGetDataFromCDText(aDrive, aTrack: Integer): Boolean;

            procedure fGetDataFromCDDB(aDrive, aTrack: Integer; CheckOnline: Boolean);



        public
            property Title    : String  read fTitle     ;
            property Artist   : String  read fArtist    ;
            property Album    : String  read fAlbum     ;
            property Duration : Integer read fDuration  ;
            property Track    : Integer read fTrack     ;
            property Year     : String  read fYear      ;
            property Genre    : String  read fGenre     ;
            property CddbID   : String  read fCddbID    ;

            constructor Create;

            function GetData(aPath: String; UseCDDB: Boolean): TCddaError;

    end;

    procedure EnsureDriveListIsFilled;
    procedure UpdateDriveList;
    function BassErrorToCDError(aError: Integer): TCddaError;

    function SameDrive(A, B: String): Boolean;
    function AudioDriveNumber(aPath: String): Integer;
    function CoverFilenameFromCDDA(aPath: String): String;
    function CddbIDFromCDDA(aPath: String): String;

    procedure ClearCDDBCache(aIdx: Integer = -1);



var
    CDDriveList: TObjectList;



implementation

procedure EnsureDriveListIsFilled;
var cdi : BASS_CD_INFO ;
    newCDDrive: TCDDADrive;
    idx: Integer;
begin
    if not assigned(CDDriveList) then
    begin
        CDDriveList := TObjectList.Create(True);

        // Get list of available drives
        idx := 0;
        while (idx < MAXDRIVES) and BASS_CD_GetInfo(idx, cdi) do
        begin
            newCDDrive := TCDDADrive.Create;
            newCDDrive.Vendor    := cdi.vendor;
            newCDDrive.Product   := cdi.product;
            newCDDrive.Revision  := cdi.rev;
            newCDDrive.Letter    := Char(cdi.letter + Ord('A'));
            newCDDrive.fIndex    := idx;
            CDDriveList.Add(newCDDrive);
            inc(idx);
        end;
    end;
end;

procedure UpdateDriveList;
var cdi : BASS_CD_INFO ;
    newCDDrive, aDrive: TCDDADrive;
    idx, idxDrives, FoundIdx: Integer;
    tmpDriveList: TObjectList;
begin
    if not assigned(CDDriveList) then
        CDDriveList := TObjectList.Create(True);

    tmpDriveList := TObjectList.Create(False);
    try
        // Get list of available drives
        idx := 0;
        while (idx < MAXDRIVES) and BASS_CD_GetInfo(idx, cdi) do
        begin
            // search Drive in List
            FoundIdx := -1;
            for idxDrives := 0 to CDDriveList.Count - 1 do
            begin
                aDrive :=  TCDDADrive(CDDriveList[idxDrives]);
                if (aDrive.Vendor = cdi.vendor)
                  and (aDrive.Product = cdi.product)
                  and (aDrive.Revision = cdi.rev)
                  and (aDrive.Letter = Char(cdi.letter + Ord('A')))
                  // Check ID from new Index, compare with cached entry
                  and (BASS_CD_GetID(idx, BASS_CDID_CDDB) = aDrive.fCachedCddbID)
                then begin
                    // drive is already there
                    // Change index, copy other stuff from current this drive
                    FoundIdx := idxDrives;
                    break;
                end;
            end;

            newCDDrive := TCDDADrive.Create;

            if FoundIdx > -1  then
            begin
                newCDDrive.Assign(TCDDADrive(CDDriveList[FoundIdx]));
                newCDDrive.fIndex := idx;
            end else
            begin
                newCDDrive.Vendor    := cdi.vendor;
                newCDDrive.Product   := cdi.product;
                newCDDrive.Revision  := cdi.rev;
                newCDDrive.Letter    := Char(cdi.letter + Ord('A'));
                newCDDrive.fIndex    := idx;
            end;
            tmpDriveList.Add(newCDDrive);

            inc(idx);
        end;

        // now: delete old list and copy tmp list to original list
        CDDriveList.Clear;
        for idx := 0 to tmpDriveList.Count - 1 do
            CDDriveList.Add(tmpDriveList[idx]);

    finally
        tmpDriveList.Free;
    end;
end;

function BassErrorToCDError(aError: Integer): TCddaError;
begin
    case aError of
        BASS_ERROR_DEVICE   : result := cddaErr_InvalidDrive;
        BASS_ERROR_NOCD     : result := cddaErr_DriveNotReady;
        BASS_ERROR_CDTRACK  : result := cddaErr_invalidTrackNumber;
        BASS_ERROR_NOTAUDIO : result := cddaErr_NoAudioTrack;
    else
        result := cddaErr_Unknown;
    end;
end;

function SameDrive(A, B: String): Boolean;
var cd: TCDDAFile;
    DriveA: Char;
begin
    cd := TCDDAFile.Create;
    try
        DriveA := cd.fGetDriveChar(A);
        result := DriveA = cd.fGetDriveChar(B);
    finally
        cd.Free;
    end;
end;

function AudioDriveNumber(aPath: String): Integer;
var cd: TCDDAFile;
begin
    cd := TCDDAFile.Create;
    try
        if cd.fGetDriveChar(aPath) <> #0 then
            // Get DriveNumber from DriveLetter
            result := cd.fGetDriveNumber(cd.fDriveLetter)
        else
            result := -1;
    finally
        cd.Free;
    end;
end;

function CoverFilenameFromCDDA(aPath: String): String;
var aDrive: Integer;
begin
    aDrive := AudioDriveNumber(aPath);
    result := String(BASS_CD_GetID(aDrive,BASS_CDID_CDDB));
    result := StringReplace(result, ' ', '-', [rfReplaceAll]);
    if Length(result) > 32 then
        SetLength(Result, 32);
end;

function CddbIDFromCDDA(aPath: String): String;
var aDrive: Integer;
begin
    aDrive := AudioDriveNumber(aPath);
    result := String(BASS_CD_GetID(aDrive,BASS_CDID_CDDB));
end;


procedure ClearCDDBCache(aIdx: Integer = -1);
var i: Integer;
begin
    if assigned(CDDriveList) then
    begin
        if aIdx = -1 then
            for i := 0 to CDDriveList.Count - 1 do
            begin
                TCDDADrive(CDDriveList[i]).fCachedCddbData := '';
                TCDDADrive(CDDriveList[i]).fCachedCddbID   := '';
                TCDDADrive(CDDriveList[i]).fIsCompilation  := False;
                TCDDADrive(CDDriveList[i]).fDelimter       := #0;
            end
        else
        begin
            // just the index
            if (aIdx >= 0) and (aIdx < CDDriveList.Count) then
            begin
                TCDDADrive(CDDriveList[aIdx]).fCachedCddbData := '';
                TCDDADrive(CDDriveList[aIdx]).fCachedCddbID   := '';
                TCDDADrive(CDDriveList[aIdx]).fIsCompilation  := False;
                TCDDADrive(CDDriveList[aIdx]).fDelimter       := #0;
            end;
        end;

    end;
end;

{ TCDDADrive }

procedure TCDDADrive.Assign(aDrive: TCDDADrive);
begin
    fCachedCddbData := aDrive.fCachedCddbData;
    fCachedCddbID   := aDrive.fCachedCddbID  ;
    fIndex          := aDrive.fIndex         ;
    fIsCompilation  := aDrive.fIsCompilation ;
    fDelimter       := aDrive.fDelimter      ;
    Vendor          := aDrive.Vendor         ;
    Product         := aDrive.Product        ;
    Revision        := aDrive.Revision       ;
    Letter          := aDrive.Letter         ;
end;

procedure TCDDADrive.CheckForCompilation(aData: AnsiString);
var sl: TStringList;
    i: integer;
    cMinus, cSlash, c: Integer;
begin
    fIsCompilation := False;
    cMinus := 0;
    cSlash := 0;
    c := 0;

    sl := TStringList.Create;
    try
        sl.Text := String(aData);
        for i := 0 to sl.Count - 1 do
        begin
            if AnsiStartstext('TTITLE', sl[i]) then
            begin
                c := c + 1;
                if pos(' - ', sl[i]) > 0 then
                    cMinus := cMinus + 1;
                if pos(' / ', sl[i]) > 0 then
                    cSlash := cSlash + 1;
            end;
        end;

        if cSlash >= c-2 then
        begin
            fIsCompilation := True;
            self.fDelimter := '/';
        end else
        if cMinus >= c-2 then
        begin
            fIsCompilation := True;
            self.fDelimter := '-';
        end;
    finally
        sl.Free;
    end;

end;

function TCDDADrive.GetCDDBData(CheckOnline: Boolean): AnsiString;
var newCddbID, queryReply: PAnsiChar;

begin
    //
    newCddbID := BASS_CD_GetID(self.fIndex, BASS_CDID_CDDB);
    if newCddbID <> NIL then
    begin
        if newCddbID = fCachedCddbID then
            // return cached Data
            result := fCachedCddbData
        else
        begin
            if CheckOnline then
            begin
                // get new DATA
                fCachedCddbID := newCddbID;

                // 1. Query
                queryReply := BASS_CD_GetID(self.fIndex, BASS_CDID_CDDB_QUERY);

                if AnsiStartsText('200', String(queryReply)) then
                begin
                    // only one entry for this disc found
                    fCachedCddbData := BASS_CD_GetID(self.fIndex, BASS_CDID_CDDB_READ + 0);
                end else
                begin
                    if AnsiStartsText('210', String(queryReply))
                        or AnsiStartsText('211', String(queryReply))
                    then
                    begin
                        // User selection needed
                        if not assigned(FormCDDBSelect) then
                            Application.CreateForm(TFormCDDBSelect, FormCDDBSelect);
                        FormCDDBSelect.FillView(queryReply);

                        if FormCDDBSelect.ShowModal = mrOK then
                        begin
                            fCachedCddbData := BASS_CD_GetID(self.fIndex, BASS_CDID_CDDB_READ + FormCDDBSelect.SelectedEntry);
                            CheckForCompilation(fCachedCddbData);
                        end else
                        begin
                            // canceled by user
                            // fCachedCddbID := '';
                            fCachedCddbData := '';
                            result := '';
                        end;
                    end else
                    begin
                        // some error occured
                        fCachedCddbData := '';
                        // fCachedCddbID := '';
                        // showmessage(queryReply);
                        result := '';
                    end;
                end;
                result := fCachedCddbData;

            end
            else // No Online-Check
                result := '';
        end;
    end else
        result := '';
end;



{ TCDDAFile }

constructor TCDDAFile.Create;
begin
    // Get List of all Drives, if not already done
    EnsureDriveListIsFilled;
end;


{
    --------------------------------------------------------
    fGetDriveChar
    Get the driveChar X from a Path.
    Possible formats:  "X:\TrackYY.cda" or "cd(d)a://X,Y"
    --------------------------------------------------------
}
function TCDDAFile.fGetDriveChar(aPath: String): Char;
var idx: Integer;
begin
    idx := pos('://', aPath);

    if (idx > 0) then
    begin
        if length(aPath) >= idx + 3 then
            fDriveLetter := aPath[idx+3]
        else
            fDriveLetter := #0;  // invalid Path
    end else
    begin
        if length(aPath) > 0 then
            fDriveLetter := aPath[1]
        else
            fDriveLetter := #0; // invalid Path
    end;

    result := fDriveLetter;
end;

{
    --------------------------------------------------------
    fGetTrackNumber
    Get the TrackNumber Y from a Path
    Possible formats: "X:\TrackYY.cda" or "cd(d)a://X,Y"
    --------------------------------------------------------
}
function TCDDAFile.fGetTrackNumber(aPath: String): Integer;
var i: Integer;
    numberString: String;
    numberFound: Boolean;
begin
    numberString := '';
    numberFound := False;
    for i := 1 to length(aPath) do
    begin
        if CharInSet(apath[i], ['0','1','2','3','4','5','6','7','8','9']) then
        begin
            numberFound := True;
            numberString := numberString + aPath[i];
        end else
        begin
            if numberFound then
                break;
        end;
    end;

    fTrack := StrToIntDef(numberString, -1);
    result := fTrack;
end;

{
    --------------------------------------------------------
    fGetDriveNumber
    Get the driveNumber for a fiven DriveLetter
    --------------------------------------------------------
}
function TCDDAFile.fGetDriveNumber(aDriveChar: Char): Integer;
var i: integer;
begin
    fDriveNumber := -1;
    for i := 0 to CDDriveList.Count - 1 do
    begin
        if TCDDADrive(CDDriveList[i]).Letter = aDriveChar then
        begin
            fDriveNumber := i;
            break;
        end;
    end;
    result := fDriveNumber;
end;

{
    --------------------------------------------------------
    fGetDataFromCDText
    Get Artist/Titel/Album from CD-Text
    --------------------------------------------------------
}
function TCDDAFile.fGetDataFromCDText(aDrive, aTrack: Integer): Boolean;
var CompleteText: PAnsiChar;

      function GetValue(aKey: String; aText: PAnsiChar): String;
      var tmp: PAnsiChar;
      begin
          result := '';
          tmp := aText;
          while (trim(String(tmp)) <> '') do
          begin
              if AnsiStartsText(string(aKey), string(tmp)) then
              begin
                  // we found the entry
                  result := String(Copy(tmp, Length(aKey)+2, Length(tmp) - Length(aKey)));
                  break;
              end;
              tmp := tmp + Length(tmp) +1 ;
          end;
      end;

begin
    CompleteText := BASS_CD_GetID(aDrive, BASS_CDID_TEXT);
    if CompleteText <> NIL then
    begin
        result := True;
        fGenre := '';
        fYear  := '';
        fAlbum := GetValue('TITLE0', CompleteText);
        fTitle := GetValue('TITLE'+IntToStr(aTrack), CompleteText);
        fArtist:= GetValue('PERFORMER'+IntToStr(aTrack), CompleteText);
        if fArtist = '' then
            fArtist:= GetValue('PERFORMER0', CompleteText); // Album-Artist

        if AnsiStartsText(fArtist, fAlbum) then
            fAlbum := Trim(StringReplace(fAlbum, fArtist, '', [rfReplaceAll]));

    end else
        result := False;
end;


{
    --------------------------------------------------------
    fGetDataFromCDDB
    Get Artist/Titel/Album from CDDB // freeDB
    --------------------------------------------------------
}
procedure TCDDAFile.fGetDataFromCDDB(aDrive, aTrack: Integer; CheckOnline: Boolean);
var CompleteData: AnsiString;
    sl: TStringList;
    idx: Integer;
    tmp: String;

    function GetValue(aKey: String): String;
    var i: Integer;
    begin
        result := '';
        for i := 0 to sl.Count - 1 do
        begin
            if AnsiStartsText(aKey, sl[i]) then
            begin
                result := Copy(sl[i], Length(aKey)+2, Length(sl[i]) - Length(aKey));
                break;
            end;
        end;
    end;

begin
    // get DISC-freedb-ID
    // check, whether the drive aDrive has Cached this
    //     No: Download data and cache it
    //    Yes: Use cached Data


    CompleteData := TCDDADrive(CDDriveList[aDrive]).GetCDDBData(CheckOnline);

    if CompleteData <> '' then
    begin
        sl := TStringList.Create;
        try
            sl.Text := String(CompleteData);

            fYear  := GetValue('DYEAR');
            fGenre := GetValue('DGENRE');
            tmp    := GetValue('DTITLE');

            idx := Pos(' - ', tmp);
            if idx = 0 then
                idx := Pos(' / ', tmp);
            if idx > 0 then
            begin
                fAlbum  := Copy(tmp, idx + 3, Length(tmp));
                fArtist := Copy(tmp, 1, idx);
            end else
                fAlbum := tmp;


            if TCDDADrive(CDDriveList[aDrive]).fIsCompilation then
            begin
                // Get Title and Artist
                tmp := GetValue('TTITLE' + IntToStr(aTrack));

                idx := Pos(' '+TCDDADrive(CDDriveList[aDrive]).fDelimter+' ', tmp);
                fTitle := Copy(tmp, idx + 3, Length(tmp));
                fArtist := Copy(tmp, 1, idx);
            end else
            begin
                fTitle := GetValue('TTITLE' + IntToStr(aTrack));
            end;
        finally
            sl.Free
        end;
    end;
end;


function TCDDAFile.GetData(aPath: String; UseCDDB: Boolean): TCddaError;
var ByteLength: DWord;
begin

    // Get DriveLetter from Path
    if fGetDriveChar(aPath) <> #0 then
    begin
        // Get DriveNumber from DriveLetter
        if fGetDriveNumber(fDriveLetter) > -1 then
        begin
            if fGetTrackNumber(aPath) > -1 then
            begin
                // we found the DriveNr and TrackNr for this file, which is needed for the bass-cd-methods
                if BASS_CD_IsReady(fDriveNumber) then
                begin
                    // Get Duration
                    ByteLength := BASS_CD_GetTrackLength(fDriveNumber, fTrack-1); // This method wants Track=0 for the first track ;-)
                    if ByteLength = High(DWord) then
                    begin
                        {case BASS_ErrorGetCode of
                            BASS_ERROR_NOTAUDIO:
                             begin
                                fArtist := '';
                                fTitle := '';
                                fAlbum := '';
                                fGenre := '';
                                fYear  := '';
                                result := cddaErr_None;
                            end
                        else}
                            result := BassErrorToCDError(BASS_ErrorGetCode)
                        {end;}

                    end
                    else
                    begin
                        // There is a CD, the track is valid. So: we can finally begin to check for
                        // some more information
                        result := cddaErr_None;
                        // CD audio is always 44100hz stereo 16-bit. That is 176400 bytes per second.
                        fDuration := ByteLength Div 176400;

                        fCddbID := String(BASS_CD_GetID(fDriveNumber, BASS_CDID_CDDB));

                        if not fGetDataFromCDText(fDriveNumber, fTrack) then
                        begin
                            // if UseCDDB then
                                // get data from cddb
                                fGetDataFromCDDB(fDriveNumber, fTrack-1, UseCDDB);
                        end;
                    end;
                end else
                    result := cddaErr_DriveNotReady;
            end else
                result := cddaErr_invalidTrackNumber;
        end else
            result := cddaErr_invalidDrive;
    end else
        result := cddaErr_invalidPath;
end;


initialization

    CDDriveList := Nil;

finalization

    if assigned(CDDriveList) then
        CDDriveList.Free;

end.
