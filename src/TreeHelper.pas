{

    Unit TreeHelper

    - Some Helper for Trees.

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
unit TreeHelper;

interface

uses Windows, Graphics, SysUtils, VirtualTrees, Forms, Controls, NempAudioFiles, Types, StrUtils,
  Contnrs, Classes, Jpeg, PNGImage, uDragFilesSrc, math,
  Mp3FileUtils, Id3v2Frames, dialogs, Hilfsfunktionen,
  Nemp_ConstantsAndTypes, CoverHelper, MedienbibliothekClass, BibHelper,
  gnuGettext, Nemp_RessourceStrings;


type
  TStringTreeData = record
      FString : TJustaString;
  end;
  PStringTreeData = ^TStringTreeData;

  function LengthToSize(len:integer; def:integer):integer;
  function MaxFontSize(default: Integer): Integer;

  function ModeToStyle(m:Byte):TFontstyles;

  function FontSelectorItemIndexToStyle(m: Integer):TFontstyles;


  function GetColumnIDfromPosition(aVST:TVirtualStringTree; position:LongWord):integer;
  function GetColumnIDfromContent(aVST:TVirtualStringTree; content:integer):integer;

  function AddVSTString(AVST: TCustomVirtualStringTree; aNode: PVirtualNode; aString: TJustaString): PVirtualNode;

  procedure FillStringTree(Liste: TObjectList; aTree: TVirtualStringTree; Playlist: Boolean = False);
  procedure FillStringTreeWithSubNodes(Liste: TObjectList; aTree: TVirtualStringTree; Playlist: Boolean = False);

  function GetOldNode(aString: UnicodeString; aTree: TVirtualStringTree): PVirtualNode;

  function GetNextNodeOrFirst(aTree: TVirtualStringTree; aNode: PVirtualNode): PVirtualNode;
  function GetNodeWithAudioFile(aTree: TVirtualStringTree; aAudioFile: TAudioFile): PVirtualNode;
  function GetNodeWithIndex(aTree: TVirtualStringTree; aIndex: Cardinal; StartNode: PVirtualNode): PVirtualNode;

  procedure InitiateDragDrop(aTree: TVirtualStringTree; aList: TStringList; DragDrop: TDragFilesSrc; maxFiles: Integer);

  function InitiateFocussedPlay(aTree: TVirtualStringTree): Boolean;


implementation

Uses  NempMainUnit, PlayerClass,  MainFormHelper;

// Diese Listen brauche ich bei der Ordner-Ansicht:
// Da gibts ja u.U. mehr Knoten, als ich tats�chlich Ordner habe, um die Unterordner-Struktur mit aufzubauen
var  ZusatzJustaStringsArtists: TObjectlist;
     ZusatzJustaStringsAlben: TObjectlist;


function MaxFontSize(default: Integer): Integer;
begin
    // sync with function LengthToSize!
    result := default + 2;
end;

function LengthToSize(len:integer;def:integer):integer;
begin
  with Nemp_MainForm do
  begin
    //if len < NempOptions.MaxDauer[1] then result := NempOptions.FontSize[1]
    //else if len < NempOptions.MaxDauer[2] then result := NempOptions.FontSize[2]
    //else if len < NempOptions.MaxDauer[3] then result := NempOptions.FontSize[3]
    //else if len < NempOptions.MaxDauer[4] then result := NempOptions.FontSize[4]
    //else  result := NempOptions.FontSize[5]

    if len < NempOptions.MaxDauer[1] then result := def - 2
    else if len < NempOptions.MaxDauer[2] then result := def - 1
    else if len < NempOptions.MaxDauer[3] then result := def
    else if len < NempOptions.MaxDauer[4] then result := def + 1
    else  result := def + 2;

    if result < 4 then
        result := 4;
  end;
end;

function ModeToStyle(m:Byte):TFontstyles;
begin
  // ('S ','JS','DC','M ','--');
  case m of
    0,2: result := [fsbold];
    1,4: result := [];
    else result := [fsitalic];
  end;
end;

function FontSelectorItemIndexToStyle(m: Integer): TFontstyles;
begin
    case m of
        0: result := [];
        1: result := [fsbold];
        2: result := [fsitalic];
        3: result := [fsbold, fsitalic];
    else
        result := [];
    end;
end;


function GetColumnIDfromPosition(aVST:TVirtualStringTree; position:LongWord):integer;
var i:integer;
begin
  result := 0;
  for i:=0 to aVST.Header.Columns.Count-1 do
    if aVST.Header.Columns[i].Position = position then
      result := i;
end;

function GetColumnIDfromContent(aVST:TVirtualStringTree; content:integer):integer;
var i:integer;
begin
  result := 0;
  for i:=0 to aVST.Header.Columns.Count-1 do
    if aVST.Header.Columns[i].Tag = content then
      result := i;
end;


function AddVSTString(AVST: TCustomVirtualStringTree; aNode: PVirtualNode; aString: TJustaString): PVirtualNode;
var Data: PStringTreeData;
begin
  Result:= AVST.AddChild(aNode); // meistens wohl Nil
  AVST.ValidateNode(Result,false); // ?? was macht das??
  Data:=AVST.GetNodeData(Result);
  Data^.FString := aString;
end;


procedure FillStringTree(Liste: TObjectList; aTree: TVirtualStringTree; Playlist: Boolean = False);
var i, cAdd, startIdx: integer;
  HeaderStr: String;
  rn: PVirtualNode;
begin
  aTree.BeginUpdate;
  aTree.Clear;

  if aTree = Nemp_MainForm.ArtistsVST then
  begin
      startIdx := 3;
      if Liste.Count > 0 then
          AddVSTString(aTree, Nil, TJustaString(Liste[0])); // All Playlists
      if Liste.Count > 1 then
          AddVSTString(aTree, Nil, TJustaString(Liste[1])); // <Webradio>
      if Liste.Count > 2 then
          rn := AddVSTString(aTree, Nil, TJustaString(Liste[2])) // <All>
      else
          rn := NIL;  // Dann ist aber was falsch!!!
  end else
  begin
      startIdx := 1;
      if Liste.Count > 0 then
        AddVSTString(aTree,Nil,TJustaString(Liste[0]));
      //else
        rn := NIL; // Das sollte aber niemals auftreten!!
  end;

  for i := startIdx to Liste.Count-1 do
    AddVSTString(aTree, rn, TJustaString(Liste[i]));

  if (MedienBib.CurrentArtist = BROWSE_PLAYLISTS) and (aTree.Tag = 2) then // d.h. es ist der alben-Tree
  begin
      HeaderStr := TreeHeader_Playlists;
      cAdd := 1;
  end else
  if (MedienBib.CurrentArtist = BROWSE_RADIOSTATIONS) and (aTree.Tag = 2) then
  begin
      HeaderStr := TreeHeader_Webradio;
      cAdd := 1;
  end
  else
  begin
      cAdd := 0;
      case MedienBib.NempSortArray[aTree.Tag] of
        siAlbum:  HeaderStr := (TreeHeader_Albums);
        siArtist: HeaderStr := (TreeHeader_Artists);
        siOrdner: HeaderStr := (TreeHeader_Directories);
        siGenre:  HeaderStr := (TreeHeader_Genres);
        siJahr:   HeaderStr := (TreeHeader_Years);
        siFileAge:HeaderStr := (TreeHeader_FileAges);
        else HeaderStr := '(N/A)';
      end;
  end;
  if Liste.Count > 0 then
    aTree.Header.Columns[0].Text := HeaderStr + ' (' + inttostr(Liste.Count-1 + cAdd) + ')'
  else
    aTree.Header.Columns[0].Text := HeaderStr;

  //aTree.FullExpand;  --> this requires a lot of time ???
  aTree.EndUpdate;
end;

procedure FillStringTreeWithSubNodes(Liste: TObjectList; aTree: TVirtualStringTree; Playlist: Boolean = False);
var i,n,ncount,max, cAdd, startIdx: integer;
  NewOrdner: UnicodeString;
  Ordnerstruktur: TStringList;
  NewCheckNode, CheckNode, rn: PVirtualNode;
  Data : PStringTreeData;
  subOrdner: UnicodeString;
  jas: TJustAString;
  HeaderStr: String;
  aObjectList: TObjectlist;
begin
  aTree.BeginUpdate;
  aTree.Clear;
  if aTree = Nemp_MainForm.ArtistsVST then
    aObjectlist := ZusatzJustaStringsArtists
  else
    aObjectList := ZusatzJustaStringsAlben;

  aObjectList.Clear;

  if aTree = Nemp_MainForm.ArtistsVST then
  begin
      startIdx := 3;
      if Liste.Count > 0 then
          AddVSTString(aTree, Nil, TJustaString(Liste[0])); // All Playlists
      if Liste.Count > 1 then
          AddVSTString(aTree, Nil, TJustaString(Liste[1])); // Webradio
      if Liste.Count > 2 then
          rn := AddVSTString(aTree, Nil, TJustaString(Liste[2])) // <All>
      else
          rn := NIL;  // Dann ist aber was falsch!!!
  end else
  begin
      startIdx := 1;
      if Liste.Count > 0 then
        rn := AddVSTString(aTree,Nil,TJustaString(Liste[0]))
      else
        rn := NIL; // Das sollte aber niemals auftreten!!
  end;

  for i := startIdx to Liste.Count - 1 do
  begin
    // Newordner ist der neue Ordner, der in die Baumansicht eingef�gt werden soll
    NewOrdner := TJustaString(Liste[i]).DataString;

    Ordnerstruktur := Explode('\', NewOrdner);

    if (Ordnerstruktur.Count >= 3) and (Ordnerstruktur[0] = '') and (Ordnerstruktur[1] = '') then
    begin
        Ordnerstruktur[2] := '\\' + Ordnerstruktur[2];
        Ordnerstruktur.Delete(0); // die beiden ersten wieder l�schen
        Ordnerstruktur.Delete(0); // die beiden ersten wieder l�schen
    end;

    max := Ordnerstruktur.Count - 1;

    // Das ist der Knoten, an den ich anh�ngen muss
    CheckNode := rn;
    n := 0;

    subOrdner := '';
    // Das ist der Knoten, mit dem ich vergleichen muss
    // stimmen die Daten dort �berein, kann ich dort (oder weiter unten anh�ngen)
    NewCheckNode := atree.GetLastChild(CheckNode);

    if assigned(NewChecknode) then
    begin
        Data := aTree.GetNodeData(NewCheckNode);
        // solange der Ordner �bereinstimmt, kann ich eine Stufe tiefer gehen.
        while (n <= max) AND (assigned(NewChecknode)) AND (Data^.FString.AnzeigeString = Ordnerstruktur[n] + '\') do
        begin
            SubOrdner := SubOrdner + Ordnerstruktur[n] + '\';
            Checknode := NewChecknode;
            NewChecknode := aTree.GetLastChild(CheckNode);
            if assigned(NewChecknode) then
              Data := aTree.GetNodeData(NewCheckNode);
            inc(n);
        end;
    end;

    // n kann eigentlich niemals gleich max werden. Denke ich zumindest.

    // Jetzt ist checknode der Knoten, an den ich anh�ngen muss
    // Aber: nicht einfach den neuen String, sondern erstmal ggf. Unterverzeichnisse

    // Ordnerstruktur[n] ist der erste Ordner in der Hierarchie, der noch nicht im Baum ist
    for ncount := n to max-1 do
    begin
      //hier m�ssen wird noch JustaStrings erzeugen.
      SubOrdner := SubOrdner + Ordnerstruktur[ncount] + '\';
      jas := TJustaString.create(SubOrdner, Ordnerstruktur[ncount] + '\');
      aObjectList.Add(jas);
      CheckNode := AddVSTString(aTree,Checknode,jas);
    end;
    // am Ende das richtige einf�rgen
    jas := TJustaString.create(NewOrdner, Ordnerstruktur[max] + '\');
    aObjectList.Add(jas);
    AddVSTString(aTree,Checknode,jas);
    Ordnerstruktur.Free;
  end;
  if rn <> NIl then
      aTree.Expanded[rn] := True;

  if (MedienBib.CurrentArtist = BROWSE_PLAYLISTS) and (aTree.Tag = 2) then // d.h. es ist der alben-Tree
  begin
      HeaderStr := TreeHeader_Playlists;
      cAdd := 1;
  end else
  if (MedienBib.CurrentArtist = BROWSE_RADIOSTATIONS) and (aTree.Tag = 2) then
  begin
      HeaderStr := TreeHeader_Webradio;
      cAdd := 1;
  end
  else
  begin
      cAdd := 0;
      case MedienBib.NempSortArray[aTree.Tag] of
        siAlbum:  HeaderStr := (TreeHeader_Albums); 
        siArtist: HeaderStr := (TreeHeader_Artists);
        siOrdner: HeaderStr := (TreeHeader_Directories);
        siGenre:  HeaderStr := (TreeHeader_Genres);
        siJahr:   HeaderStr := (TreeHeader_Years);
        siFileAge:HeaderStr := (TreeHeader_FileAges);
        else HeaderStr := '(N/A)';
      end;
  end;
  if Liste.Count > 0 then
    aTree.Header.Columns[0].Text := HeaderStr + ' (' + inttostr(Liste.Count-1 + cAdd) + ')'
  else
    aTree.Header.Columns[0].Text := HeaderStr;

  aTree.EndUpdate;
end;


function GetOldNode(aString: UnicodeString; aTree: TVirtualStringTree): PVirtualNode;
var aData: PStringTreeData;
    currentString: UnicodeString;
    c: Integer;
    found: Boolean;
begin
    result := aTree.GetFirst;

    // Search for the empty-DataString
    // If it is not in the first 5 Nodes, it surely doesnt exist any longer.
    // return first node then
    if aString = '' then
    begin
        if assigned(result) then
        begin
            c := 1;
            found := False;
            repeat
                aData := aTree.GetNodeData(result);
                if TJustAstring(aData^.FString).DataString = '' then
                    found := True
                else
                begin
                    inc(c);
                    result := aTree.GetNext(result);
                end;
            until (Not assigned(result)) OR Found OR (C > 5);
            if Not Found then
                result := aTree.GetFirst;
        end;
    end else
    begin
        // some "real"-DataString. Search until Current >= aString
        if assigned(result) then
        begin
            repeat
                aData := aTree.GetNodeData(result);
                currentString := TJustAstring(aData^.FString).DataString;
                if AnsiCompareText(currentString, aString) < 0 then
                    result := aTree.GetNext(result);
            until (Not assigned(result)) OR
                              (AnsiCompareText(currentString, aString) >= 0);

          {  if assigned(result) and ((currentString = AUDIOFILE_UNKOWN) and (aString <> AUDIOFILE_UNKOWN) )  then
            begin
                result := aTree.GetNext(result);
                aData := aTree.GetNodeData(result);
                currentString := TJustAstring(aData^.FString).DataString;
                // weitersuchen
                while Assigned(result) and (AnsiCompareText(currentString, aString) < 0) do
                begin
                    result := aTree.GetNext(result);
                    aData := aTree.GetNodeData(result);
                    currentString := TJustAstring(aData^.FString).DataString;
                end;
            end;
            }
        end
    end;
end;

function GetNextNodeOrFirst(aTree: TVirtualStringTree; aNode: PVirtualNode): PVirtualNode;
begin
    result := aTree.GetNextSibling(aNode);
    if not assigned(result) then
        result := aTree.GetFirst;
end;

function GetNodeWithAudioFile(aTree: TVirtualStringTree; aAudioFile: TAudioFile): PVirtualNode;
var aNode: PVirtualNode;
begin
    result := Nil;
    aNode := aTree.GetFirst;

    while assigned(aNode) and (Not assigned(result)) do
    begin
        if aTree.GetNodeData<TAudioFile>(aNode) = aAudioFile then
            result := aNode
        else
            aNode := aTree.GetNextSibling(aNode);
    end;
end;

function GetNodeWithIndex(aTree: TVirtualStringTree; aIndex: Cardinal; StartNode: PVirtualNode): PVirtualNode;
begin
    if assigned(StartNode) and (StartNode.Index <= aIndex) then
        result := StartNode
    else
        result := aTree.GetFirst;

    while assigned(result) and (result.Index <> aIndex) do
        result := aTree.GetNextSibling(result);
end;

function InitiateFocussedPlay(aTree: TVirtualStringTree): Boolean;
var MainNode, CueNode: PVirtualNode;
begin
    MainNode := aTree.FocusedNode;
    if not assigned(MainNode) then
    begin
          result := False;
          exit;
    end;

    NempPlaylist.UserInput;
    NempPlayer.LastUserWish := USER_WANT_PLAY;

    result := True;
    if aTree.GetNodeLevel(MainNode) = 0 then
    begin
        NempPlaylist.PlayFocussed(MainNode.Index, -1);
    end else
    begin
        CueNode := MainNode;
        MainNode := aTree.NodeParent[MainNode];
        NempPlaylist.PlayFocussed(MainNode.Index, CueNode.Index);
    end;
end;


procedure InitiateDragDrop(aTree: TVirtualStringTree; aList: TStringList; DragDrop: TDragFilesSrc; maxFiles: Integer);
var i, maxC: Integer;
    SelectedMp3s: TNodeArray;
    af: TAudioFile;
    cueFile: String;
begin
    // Add files selected to DragFilesSrc1 list
    DragDrop.ClearFiles;
    aList.Clear;
    SelectedMp3s := aTree.GetSortedSelection(False);
    maxC := min(maxFiles, length(SelectedMp3s));
    if length(SelectedMp3s) > maxFiles then
        AddErrorLog(Format(Warning_TooManyFiles, [maxFiles]));

    for i := 0 to maxC - 1 do
    begin
        //Data := aVST.GetNodeData(SelectedMP3s[i]);
        af := aTree.GetNodeData<TAudioFile>(SelectedMp3s[i]);
        DragDrop.AddFile(af.Pfad);
        aList.Add(af.Pfad);
        if (af.Duration > MIN_CUESHEET_DURATION) then
        begin
            cueFile := ChangeFileExt(af.Pfad, '.cue');
            if FileExists(ChangeFileExt(af.Pfad, '.cue')) then
                // We dont need internal dragging of cue-Files, so only Addfile
                DragDrop.AddFile(cueFile);
        end;
    end;
    // This is the START of the drag (FROM) operation.
    DragDrop.Execute;
end;


initialization
  ZusatzJustaStringsArtists := TObjectlist.Create;
  ZusatzJustaStringsAlben := TObjectlist.Create;


finalization
  try
  ZusatzJustaStringsArtists.Free;
  ZusatzJustaStringsAlben.Free;
  except end;

end.
