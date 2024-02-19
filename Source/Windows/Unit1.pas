unit Unit1;

interface

{EasyNotes https://github.com/r57zone/EasyNotes}

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, OleCtrls, ExtCtrls, StdCtrls, SQLite3, SQLite3Wrap, SHDocVw, ActiveX,
  DateUtils, IniFiles, IdBaseComponent, IdComponent, IdTCPServer, IdCustomHTTPServer,
  IdHTTPServer, XMLDoc, XMLIntf, Registry, Menus, ClipBrd, MSHTML, XPMan;

type
  TMain = class(TForm)
    WebView: TWebBrowser;
    IdHTTPServer: TIdHTTPServer;
    PopupMenu: TPopupMenu;
    PasteBtn: TMenuItem;
    CutBtn: TMenuItem;
    CopyBtn: TMenuItem;
    XPManifest: TXPManifest;
    procedure FormCreate(Sender: TObject);
    procedure WebViewBeforeNavigate2(Sender: TObject;
      const pDisp: IDispatch; var URL, Flags, TargetFrameName, PostData,
      Headers: OleVariant; var Cancel: WordBool);
    procedure WebViewDocumentComplete(Sender: TObject;
      const pDisp: IDispatch; var URL: OleVariant);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormActivate(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure IdHTTPServerCommandGet(AThread: TIdPeerThread;
      ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
    procedure PasteBtnClick(Sender: TObject);
    procedure CopyBtnClick(Sender: TObject);
    procedure CutBtnClick(Sender: TObject);
    procedure AddStyle(FileName: string);
    procedure ExportNotes(FileName: string);
    procedure ImportNotes(FileName: string);
    procedure LoadNotes;
  private
    procedure NewNote(MemoFocus: boolean);
    procedure NoteDone(UpdateList: integer);
    procedure MessageHandler(var Msg: TMsg; var Handled: Boolean);
    { Private declarations }
  public
    function SQLDBTableExists(TableName: string): boolean;
	  function SQLTBCount(TableName: string): integer;
    { Public declarations }
  end;

var
  Main: TMain;
  CloseDuplicate: boolean;
  SQLDB: TSQLite3Database;
  DBFileName: string;

  OldWidth, OldHeight: integer;
  NoteIndex, NoteTimeStamp: int64; LatestNote: string;

  FOleInPlaceActiveObject: IOleInPlaceActiveObject;
  SaveMessageHandler: TMessageEvent;

  IDS_NEW_NOTE, IDS_NOTES, IDS_TODAY, IDS_YESTERDAY, IDS_DAYSAGO, IDS_SYNC: string;
  IDS_DEV_SYNC_CONFIRM, IDS_CUT, IDS_COPY, IDS_PASTE, IDS_LAST_UPDATE: string;

  IDS_SETTINGS, IDS_INTERFACE, IDS_DARK_THEME, IDS_THEME_TIME, IDS_SYNCHRONIZATION,
  IDS_SYNC_PORT, IDS_SYNC_WITH_ANY_IPS, IDS_ALLOW_IPS, IDS_ALLOW_DEVS, IDS_ALLOW_DEV_REM,
  IDS_ENTER_DEV_ID, IDS_BLOCK_REQUEST_NEW_DEVS, IDS_IMPORT, IDS_EXPORT, IDS_DONE,
  IDS_OK, IDS_CANCEL: string;

  AllowedIPs, AuthorizedDevices: TStringList;
  AllowAnyIPs, BlockReqNewDevs: boolean;
  UseDarkTheme, UseThemeTime: boolean;

const
  AppName = 'EasyNotes';
  AllowedIPsFile = 'AllowedIPs.txt';

implementation

uses Unit2;

{$R *.dfm}

//TimeStamp �� �������� GMT ��� UTC +0
function GetTimeStamp: int64;
var
 SystemTime: TSystemTime;
begin
  GetSystemTime(SystemTime);
  with SystemTime do
    Result:=DateTimeToUNIX(EncodeDate(wYear, wMonth, wDay) + EncodeTime(wHour, wMinute, wSecond, wMilliseconds));
end;

function StrToCharCodes(Str: string): string;
var
  i: integer;
begin
  Result:='';
  for i:=1 to Length(Str) do
    Result:=Result + 'x' + IntToStr( Ord( Str[i] ) );
end;

function CharCodesToStr(Str: string): string;
var
  i: integer;
begin
  Result:='';
  if Length(Str) = 0 then Exit;
  if Str[1] <> 'x' then Exit;
  Delete(Str, 1, 1);
  Str:=Str + 'x';
  while Pos('x', Str) > 0 do begin
    Result:=Result + Chr( StrToIntDef ( Copy( Str, 1, Pos('x', Str) - 1), 0 ) );
    Delete(Str, 1, Pos('x', Str));
  end;
end;

function StringToWideString(const Str: AnsiString; CodePage: Word): WideString;
var
  l: integer;
begin
  if Str = '' then
    Result:=''
  else
  begin
    l:=MultiByteToWideChar(CodePage, MB_PRECOMPOSED, PChar(@Str[1]), -1, nil, 0);
    SetLength(Result, l - 1);
    if l > 1 then
      MultiByteToWideChar(CodePage, MB_PRECOMPOSED, PChar(@Str[1]), -1, PWideChar(@Result[1]), l - 1);
  end;
end;

function StrToWideCharCodes(Str: string): string;
var
  i: integer;
  WStr: WideString;
begin
  Result:='';
  WStr:=StringToWideString(Str, CP_ACP);
  for i:=1 to Length(WStr) do
    Result:=Result + 'x' + IntToStr( Ord( WStr[i] ) );
end;

function WideCharCodesToStr(Str: string): string;
var
  i: integer;
begin
  Result:='';
  if Length(Str) = 0 then Exit;
  if Str[1] <> 'x' then Exit;
  Delete(Str, 1, 1);
  Str:=Str + 'x';
  while Pos('x', Str) > 0 do begin
    Result:=Result + WideChar( StrToIntDef ( Copy( Str, 1, Pos('x', Str) - 1), 0 ) );
    Delete(Str, 1, Pos('x', Str));
  end;
end;

function GetLocaleInformation(Flag: Integer): string;
var
  pcLCA: array [0..20] of Char;
begin
  if GetLocaleInfo(LOCALE_SYSTEM_DEFAULT, Flag, pcLCA, 19)<=0 then
    pcLCA[0]:=#0;
  Result:=pcLCA;
end;

function TMain.SQLDBTableExists(TableName: string): boolean;
var
  SQLTB: TSQLite3Statement;
begin
  Result:=false;
  SQLTB:=SQLDB.Prepare('SELECT * FROM sqlite_master WHERE name = "' + TableName + '" LIMIT 1');
  try
    if SQLTB.Step = SQLITE_ROW then
      Result:=true;
  finally
    SQLTB.Free;
  end;
end;

function TMain.SQLTBCount(TableName: string): integer;
var
  SQLTB: TSQLite3Statement;
begin
  Result:=0;
  SQLTB:=SQLDB.Prepare('SELECT * FROM ' + TableName);
  try
    while SQLTB.Step = SQLITE_ROW do begin
      Inc(Result);
    end;
  finally
    SQLTB.Free;
  end;
end;

procedure TMain.FormCreate(Sender: TObject);
var
  Ini: TIniFile;
  Reg: TRegistry;
  WND: HWND;

  CurDate: TDateTime;
  CurHour, NilTime: Word;

  i: integer;

  SQLTB: TSQLite3Statement;
  LangFile: string;
begin
  // �������������� ��������� �������
  WND:=FindWindow('TMain', AppName);
  if (WND <> 0) and (ParamStr(1) <> '-show') then begin
    SetForegroundWindow(WND);
    Halt;
  end;
  Caption:=AppName;

  Ini:=TIniFile.Create(ExtractFilePath(ParamStr(0)) + 'Config.ini');
  IdHTTPServer.DefaultPort:=Ini.ReadInteger('Main', 'Port', 735);
  AllowAnyIPs:=Ini.ReadBool('Sync', 'AllowAnyIPs', false);
  BlockReqNewDevs:=Ini.ReadBool('Sync', 'BlockRequestNewDevs', false);

  UseDarkTheme:=Ini.ReadBool('Main', 'DarkTheme', false);
  UseThemeTime:=Ini.ReadBool('Main', 'ThemeTime', false);

  // �������������� ��������� ���� �� ������� �����
  if (UseDarkTheme = false) and (UseThemeTime) then begin
    DecodeTime(Now, CurHour, NilTime, NilTime, NilTime);
    if (CurHour <= 7) or (CurHour >= 18) then
      UseDarkTheme:=true;
  end;

  Width:=Ini.ReadInteger('Main', 'Width', Width);
  Height:=Ini.ReadInteger('Main', 'Height', Height);
  OldWidth:=Width;
  OldHeight:=Height;
  if Ini.ReadBool('Main', 'FirstRun', true) then begin
    Ini.WriteBool('Main', 'FirstRun', false);
    Reg:=TRegistry.Create;
    Reg.RootKey:=HKEY_CURRENT_USER;
    if Reg.OpenKey('\Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION', true) then begin
        Reg.WriteInteger(ExtractFileName(ParamStr(0)), 11000);
      Reg.CloseKey;
    end;
    Reg.Free;
  end;
  Ini.Free;

  IdHTTPServer.Active:=true;

  // �������
  LangFile:=GetLocaleInformation(LOCALE_SENGLANGUAGE) + '.ini';
  if not FileExists(ExtractFilePath(ParamStr(0)) + 'Languages\' + LangFile) then
    LangFile:='English.ini';

  Ini:=TIniFile.Create(ExtractFilePath(ParamStr(0)) + 'Languages\' + LangFile);
  IDS_NEW_NOTE:=Ini.ReadString('Main', 'ID_NEW_NOTE', '');
  IDS_NOTES:=Ini.ReadString('Main', 'ID_NOTES', '');
  IDS_TODAY:=Ini.ReadString('Main', 'ID_TODAY', '');
  IDS_YESTERDAY:=Ini.ReadString('Main', 'ID_YESTERDAY', '');
  IDS_DAYSAGO:=Ini.ReadString('Main', 'ID_DAYSAGO', '');
  IDS_SYNC:=Ini.ReadString('Main', 'ID_SYNC', '');
  IDS_DEV_SYNC_CONFIRM:=Ini.ReadString('Main', 'ID_DEV_SYNC_CONFIRM', '');
  IDS_CUT:=Ini.ReadString('Main', 'ID_CUT', '');
  IDS_COPY:=Ini.ReadString('Main', 'ID_COPY', '');
  IDS_PASTE:=Ini.ReadString('Main', 'ID_PASTE', '');
  IDS_LAST_UPDATE:=Ini.ReadString('Main', 'ID_LAST_UPDATE', '');

  IDS_SETTINGS:=Ini.ReadString('Main', 'ID_SETTINGS', '');
  IDS_INTERFACE:=Ini.ReadString('Main', 'ID_INTERFACE', '');
  IDS_DARK_THEME:=Ini.ReadString('Main', 'ID_DARK_THEME', '');
  IDS_THEME_TIME:=Ini.ReadString('Main', 'ID_THEME_TIME', '');
  IDS_SYNCHRONIZATION:=Ini.ReadString('Main', 'ID_SYNCHRONIZATION', '');
  IDS_SYNC_PORT:=Ini.ReadString('Main', 'ID_SYNC_PORT', '');
  IDS_SYNC_WITH_ANY_IPS:=Ini.ReadString('Main', 'ID_SYNC_WITH_ANY_IPS', '');
  IDS_ALLOW_IPS:=Ini.ReadString('Main', 'ID_ALLOW_IPS', '');
  IDS_ALLOW_DEVS:=Ini.ReadString('Main', 'ID_ALLOW_DEVS', '');
  IDS_ALLOW_DEV_REM:=Ini.ReadString('Main', 'ID_ALLOW_DEV_REM', '');
  IDS_ENTER_DEV_ID:=Ini.ReadString('Main', 'ID_ENTER_DEV_ID', '');
  IDS_BLOCK_REQUEST_NEW_DEVS:=Ini.ReadString('Main', 'ID_BLOCK_REQUEST_NEW_DEVS', '');
  IDS_IMPORT:=Ini.ReadString('Main', 'ID_IMPORT', '');
  IDS_EXPORT:=Ini.ReadString('Main', 'ID_EXPORT', '');
  IDS_DONE:=Ini.ReadString('Main', 'ID_DONE', '');
  IDS_OK:=Ini.ReadString('Main', 'ID_OK', '');
  IDS_CANCEL:=Ini.ReadString('Main', 'ID_CANCEL', '');

  CutBtn.Caption:=IDS_CUT;
  CopyBtn.Caption:=IDS_COPY;
  PasteBtn.Caption:=IDS_PASTE;
  Application.Title:=Caption;
  Main.Visible:=false;
  WebView.Silent:=true;
  WebView.Navigate(ExtractFilePath(ParamStr(0)) + 'style\main.html');

  DBFileName:='Notes.db';
  for i:=1 to ParamCount do
    if (LowerCase(ParamStr(i)) = '-db') and (Trim(ParamStr(i + 1)) <> '') then begin
      DBFileName:=ParamStr(i + 1);
      break;
    end;


  SQLDB:=TSQLite3Database.Create;
  SQLDB.Open(DBFileName);

  SQLDB.Execute('CREATE TABLE IF NOT EXISTS Notes (ID TIMESTAMP, Note TEXT, DateTime TIMESTAMP)');

  // ����������� IP ������� ��� �������������
  AllowedIPs:=TStringList.Create;
  if FileExists(ExtractFilePath(ParamStr(0)) + AllowedIPsFile) then
    AllowedIPs.LoadFromFile(ExtractFilePath(ParamStr(0)) + AllowedIPsFile);

  // �������������� ����������
  AuthorizedDevices:=TStringList.Create;
  SQLTB:=SQLDB.Prepare('SELECT name FROM sqlite_master WHERE name <> "Notes"');
  try
    while SQLTB.Step = SQLITE_ROW do
      AuthorizedDevices.Add(Copy(SQLTB.ColumnText(0), 9, Length(SQLTB.ColumnText(0)))); //Actions_ �� �����
  finally
    SQLTB.Free;
  end;

  // �������, ������
  for i:=1 to ParamCount do begin
    if (LowerCase(ParamStr(i)) = '-export') and (Trim(ParamStr(i + 1)) <> '') then
      ExportNotes(ParamStr(i + 1));

    if (LowerCase(ParamStr(i)) = '-import') and (Trim(ParamStr(i + 1)) <> '') then
      ImportNotes(ParamStr(i + 1));
  end;
end;

function ExtractTitle(Str: string): string;
begin
  Str:=Trim(Str);
  if Pos(#10, Str) > 0 then
    Str:=Copy(Str, 1, Pos(#10, Str) - 1);
  if Length(Str) > 150 then
    Str:=Copy(Str, 1, 150) + '...';
  Result:=Str;
end;

function NoteDateTime(sDate: string): string; // ���� � �������
var
  mTime, nYear: string;
begin
  sDate:=DateTimeToStr(UNIXToDateTime(StrToInt64(sDate))); // ������� TimeStamp � DateTimeStr

  mTime:=Copy(sDate, Pos(' ', sDate) + 1, Length(sDate) - Pos(' ', sDate));
  nYear:=FormatDateTime('yyyy', StrToDate(Copy(sDate, 1, Pos(' ', sDate))));

  if nYear = FormatDateTime('yyyy', Date) then
    Result:=FormatDateTime('d mmm.', StrToDate(Copy(sDate, 1, Pos(' ', sDate)))) + ' ' + Copy(mTime, 1, Length(mTime) - 3)
  else
    Result:=FormatDateTime('d.mm.yyyy', StrToDate(Copy(sDate, 1, Pos(' ', sDate)))) + ', ' + Copy(mTime, 1, Length(mTime) - 3);
end;

function ListDateTime(sDate: string): string;
var
  mTime, MyDate, nYear: string; DaysAgo: integer;
begin
  sDate:=DateTimeToStr(UNIXToDateTime(StrToInt64(sDate))); // ������� TimeStamp � DateTimeStr

  DaysAgo:=DaysBetween(StrToDate(Copy(sDate, 1, Pos(' ', sDate) - 1)), Date);

  mTime:=Copy(sDate, Pos(' ', sDate) + 1, Length(sDate) - Pos(' ', sDate));

  MyDate:=FormatDateTime('d mmm.', StrToDate(Copy(sDate, 1, Pos(' ', sDate))));

  if DaysAgo < DayOfTheWeek(Date) then begin
    MyDate:=FormatDateTime('dddd', StrToDate(Copy(sDate, 1, Pos(' ', sDate))));
    MyDate[1]:=AnsiUpperCase(MyDate[1])[1];
  end;

  if DaysAgo = 0 then MyDate:=Copy(mTime, 1, Length(mTime) - 3);
  if DaysAgo = 1 then MyDate:=IDS_YESTERDAY;

  nYear:=FormatDateTime('yyyy', StrToDate(Copy(sDate, 1, Pos(' ', sDate))));
  if nYear <> FormatDateTime('yyyy', Date) then
    MyDate:=FormatDateTime('d mmm. yyyy', StrToDate(Copy(sDate, 1, Pos(' ', sDate))));

  Result:=MyDate;
end;

procedure TMain.LoadNotes;
var
  i, NotesCount: integer; SQLTB: TSQLite3Statement;
begin
  SQLTB:=SQLDB.Prepare('SELECT * FROM Notes ORDER BY DateTime DESC');
  try
    NotesCount:=0;
    WebView.OleObject.Document.getElementById('NotesCount').innerHTML:=IDS_NOTES + ' (0)';
    WebView.OleObject.Document.getElementById('items').innerHTML:='';
    while SQLTB.Step = SQLITE_ROW do begin
      WebView.OleObject.Document.getElementById('items').innerHTML:=WebView.OleObject.Document.getElementById('items').innerHTML +
      '<div onclick="document.location=''#note' + SQLTB.ColumnText(0) + ''';" id="note"><div id="title">' + ExtractTitle(CharCodesToStr(SQLTB.ColumnText(1))) + '</div><div id="date">' + ListDateTime(SQLTB.ColumnText(2))  + '</div></div>';
      Inc(NotesCount);
    end;
  finally
    WebView.OleObject.Document.getElementById('NotesCount').innerHTML:=IDS_NOTES + ' (' + IntToStr(NotesCount) + ')';
    SQLTB.Free;
  end;
end;

procedure TMain.NoteDone(UpdateList: integer);
var
  CurTimeStamp: int64; i: integer;
begin
  // Update
  if (NoteIndex <> -1) and ( Trim(LatestNote) <> Trim(WebView.OleObject.Document.getElementById('memo').innerHTML) ) then begin

    if (GetAsyncKeyState(VK_LSHIFT) <> 0) or (GetAsyncKeyState(VK_RSHIFT) <> 0) then begin //���� ����� Shift, �� �� ��������� ����
      SQLDB.Execute('UPDATE Notes SET Note="' + StrToCharCodes(WebView.OleObject.Document.getElementById('memo').innerHTML) + '" WHERE ID=' + IntToStr(NoteIndex));

      // ��������� �������� �� ��� ������� �������������� ���������. �������� ����������� ����� ��� ������������� ���� ��� ������
      for i:=0 to AuthorizedDevices.Count - 1 do
        if SQLDBTableExists('Actions_' + AuthorizedDevices.Strings[i]) then
          SQLDB.Execute('INSERT INTO Actions_' + AuthorizedDevices.Strings[i] + ' (Action, ID, Note, DateTime) values("UPDATE", "' + IntToStr(NoteIndex) + '", "' + StrToCharCodes(WebView.OleObject.Document.getElementById('memo').innerHTML) + '", "' + IntToStr(NoteTimeStamp) + '")');

    end else begin //�� ��������� (���������� ������ � ����)
	    SQLDB.Execute('UPDATE Notes SET Note="' + StrToCharCodes(WebView.OleObject.Document.getElementById('memo').innerHTML) + '", DateTime="' + IntToStr(DateTimeToUnix(Now)) + '" WHERE ID=' + IntToStr(NoteIndex));

      //��������� �������� �� ��� ������� �������������� ���������. �������� ����������� ����� ��� ������������� ���� ��� ������
      for i:=0 to AuthorizedDevices.Count - 1 do
        if SQLDBTableExists('Actions_' + AuthorizedDevices.Strings[i]) then
          SQLDB.Execute('INSERT INTO Actions_' + AuthorizedDevices.Strings[i] + ' (Action, ID, Note, DateTime) values("UPDATE", "' + IntToStr(NoteIndex) + '", "' + StrToCharCodes(WebView.OleObject.Document.getElementById('memo').innerHTML) + '", "' + IntToStr(DateTimeToUnix(Now)) + '")');
    end;
  end;

  // Add, ����������� ��� Update, ������ ��� ����������� ������� NoteIndex
  if (NoteIndex = -1) and (Trim(WebView.OleObject.Document.getElementById('memo').innerHTML) <> '') then begin
	  CurTimeStamp:=GetTimeStamp;
	  SQLDB.Execute('INSERT INTO Notes (ID, Note, DateTime) values("' + IntToStr(CurTimeStamp) + '", "' + StrToCharCodes(WebView.OleObject.Document.getElementById('memo').innerHTML) + '", "' + IntToStr(DateTimeToUnix(Now)) + '")');
	  NoteIndex:=CurTimeStamp; //��� ����, ����� ��������� ������ �� ����������� ����� � �����

    //��������� �������� �� ��� ���� �������������� ���������. �������� ����������� ����� ��� ������������� ���� ��� ������
    for i:=0 to AuthorizedDevices.Count - 1 do
      if SQLDBTableExists('Actions_' + AuthorizedDevices.Strings[i]) then
        SQLDB.Execute('INSERT INTO Actions_' + AuthorizedDevices.Strings[i] + ' (Action, ID, Note, DateTime) values("INSERT", "' + IntToStr(CurTimeStamp) + '", "' + StrToCharCodes(WebView.OleObject.Document.getElementById('memo').innerHTML) + '", "' + IntToStr(DateTimeToUnix(Now)) + '")');
  end;

  if UpdateList = 0 then begin
    LoadNotes;
    NewNote(true); // ����� �������
  end;
end;

procedure TMain.WebViewBeforeNavigate2(Sender: TObject;
  const pDisp: IDispatch; var URL, Flags, TargetFrameName, PostData,
  Headers: OleVariant; var Cancel: WordBool);
var
  sUrl: string;
  i, DaysAgo: integer;
  NoteDate, sDate: string;
  SQLTB: TSQLite3Statement;
begin
  sUrl:=ExtractFileName(StringReplace(Url, '/', '\', [rfReplaceAll]));

  if Pos('main.html', sUrl) = 0 then Cancel:=true;

  if Pos('main.html#note', sUrl) > 0 then begin
    Delete(sUrl, 1, Pos('#note', sUrl) + 4);
    NoteIndex:=StrToIntDef(sUrl, 0);
    SQLTB:=SQLDB.Prepare('SELECT * FROM Notes WHERE ID=' + sUrl);

    if SQLTB.Step = SQLITE_ROW then
      try
        WebView.OleObject.Document.getElementById('NoteTitle').innerHTML:=ExtractTitle(CharCodesToStr(SQLTB.ColumnText(1)));
        LatestNote:=CharCodesToStr(SQLTB.ColumnText(1));

        NoteTimeStamp:=StrToInt64(SQLTB.ColumnText(2)); // ��������� ��� �������������

        sDate:=DateTimeToStr(UNIXToDateTime(StrToInt64(SQLTB.ColumnText(2)))); // ������� TimeStamp � DateTimeStr
        NoteDate:=Copy(sDate, 1, Pos(' ', sDate) - 1);
        DaysAgo:=DaysBetween(StrToDate(NoteDate), Date);

        if IDS_DAYSAGO='��. �����' then begin
          if DaysAgo mod 10 = 1 then NoteDate:=IntToStr(DaysAgo) + ' ���� �����';

          if (DaysAgo mod 10 >= 2) and (DaysAgo mod 10 <= 4) then
            NoteDate:=IntToStr(DaysAgo) + ' ��� �����';

          if ( (DaysAgo mod 10 >= 5) and (DaysAgo mod 10 <= 9) ) or (DaysAgo mod 10 = 0) then
            NoteDate:=IntToStr(DaysAgo) + ' ���� �����';
        end else
          NoteDate:=IntToStr(DaysAgo) + ' ' + IDS_DAYSAGO;

        if DaysAgo = 0 then NoteDate:=IDS_TODAY;
        if DaysAgo = 1 then NoteDate:=IDS_YESTERDAY;

        WebView.OleObject.Document.getElementById('DaysAgo').innerHTML:=NoteDate;
        WebView.OleObject.Document.getElementById('DateNote').innerHTML:=NoteDateTime(SQLTB.ColumnText(2));
        WebView.OleObject.Document.getElementById('memo').innerHTML:=CharCodesToStr(SQLTB.ColumnText(1));
      finally
        SQLTB.Free;
      end;

  end;

  if sUrl = 'main.html#new' then
    NewNote(true);

  if sUrl = 'main.html#settings' then
    Settings.ShowModal;

  if sUrl = 'main.html#done' then
    NoteDone(0); // ���������, ���������, ������ "0" ��������� ������ ������� � ����������

  // �������
  if (sUrl = 'main.html#rem') and (NoteIndex <> -1) then begin
    WebView.OleObject.Document.getElementById('memo').innerHTML:='';
    SQLDB.Execute('DELETE FROM Notes WHERE ID=' + IntToStr(NoteIndex));

    // ��������� �������� �� ��� ��������� ������� �������������� ���������. �������� ����������� ����� ��� ������������� ���� ��� ������
    for i:=0 to AuthorizedDevices.Count - 1 do
      if SQLDBTableExists('Actions_' + AuthorizedDevices.Strings[i]) then
        SQLDB.Execute('INSERT INTO Actions_' +  AuthorizedDevices.Strings[i] + ' (Action, ID) values("DELETE", "' + IntToStr(NoteIndex) + '")');

    LoadNotes;
    NewNote(false);
  end;

  if (sUrl = 'main.html#memo-menu') then begin
    PasteBtn.Enabled:=Clipboard.AsText <> '';
    CutBtn.Enabled:=WebView.OleObject.Document.getElementById('memo').selectionStart <> WebView.OleObject.Document.getElementById('memo').selectionEnd;
    CopyBtn.Enabled:=CutBtn.Enabled;
    PopupMenu.Popup(Mouse.CursorPos.X, Mouse.CursorPos.Y);
  end;
end;

procedure TMain.WebViewDocumentComplete(Sender: TObject;
  const pDisp: IDispatch; var URL: OleVariant);
var
  sUrl: string;
begin
  sUrl:=ExtractFileName(StringReplace(Url, '/', '\', [rfReplaceAll]));
  if pDisp=(Sender as TWebBrowser).Application then
    if sUrl = 'main.html' then begin
      Main.Visible:=true;
      LoadNotes;
      NewNote(true);
      if UseDarkTheme then
        AddStyle(ExtractFilePath(ParamStr(0)) + 'style\darktheme.css');
    end;
end;

procedure TMain.FormClose(Sender: TObject; var Action: TCloseAction);
var
  Ini: TIniFile;
begin
  if (Main.WindowState <> wsMaximized) then
    if (OldWidth <> Width) or (OldHeight <> Height) then begin
      Ini:=TIniFile.Create(ExtractFilePath(ParamStr(0)) + 'Config.ini');
      Ini.WriteInteger('Main', 'Width', Width);
      Ini.WriteInteger('Main', 'Height', Height);
      Ini.Free;
    end;
  IdHTTPServer.Active:=false;

  // ���������, ���������, ������ "-1" �� ��������� ������ ������� � ����������
  NoteDone(-1);

  SQLDB.Free;
  Application.OnMessage:=SaveMessageHandler;
  FOleInPlaceActiveObject:=nil;
  AllowedIPs.Free;
  AuthorizedDevices.Free;
end;

procedure TMain.MessageHandler(var Msg: TMsg; var Handled: Boolean);
var
  iOIPAO: IOleInPlaceActiveObject;
  Dispatch: IDispatch;
begin
  if not Assigned(WebView) then begin
    Handled := False;
    Exit;
  end;
  Handled := (IsDialogMessage(WebView.Handle, Msg) = true);
  if (Handled) and (not WebView.Busy) then begin
    if FOleInPlaceActiveObject = nil then begin
      Dispatch := WebView.Application;
      if Dispatch <> nil then begin
        Dispatch.QueryInterface(IOleInPlaceActiveObject, iOIPAO);
        if iOIPAO <> nil then
          FOleInPlaceActiveObject:=iOIPAO;
      end;
    end;
    if FOleInPlaceActiveObject <> nil then
      if ((Msg.message = WM_KEYDOWN) or (Msg.message = WM_KEYUP)) and
        ((Msg.wParam = VK_BACK) or (Msg.wParam = VK_LEFT) or (Msg.wParam = VK_RIGHT)
        or (Msg.wParam = VK_UP) or (Msg.wParam = VK_DOWN)) then exit;
        FOleInPlaceActiveObject.TranslateAccelerator(Msg);
  end;
end;

procedure TMain.FormActivate(Sender: TObject);
begin
  SaveMessageHandler:=Application.OnMessage;
  Application.OnMessage:=MessageHandler;
end;

procedure TMain.FormDeactivate(Sender: TObject);
begin
  Application.OnMessage:=SaveMessageHandler;
end;

procedure TMain.NewNote(MemoFocus: boolean);
begin
  WebView.OleObject.Document.getElementById('NoteTitle').innerHTML:=IDS_NEW_NOTE;
  WebView.OleObject.Document.getElementById('DaysAgo').innerHTML:=IDS_TODAY;
  WebView.OleObject.Document.getElementById('DateNote').innerHTML:=FormatDateTime('d mmm. h:nn', Now);
  WebView.OleObject.Document.getElementById('memo').innerHTML:='';
  if MemoFocus then
    WebView.OleObject.Document.getElementById('memo').focus;
  NoteIndex:=-1;
  LatestNote:='';
end;

procedure TMain.IdHTTPServerCommandGet(AThread: TIdPeerThread;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
const
  AuthorizationSuccessfulStatus = 'auth:ok';
  AuthorizationDeniedStatus = 'auth:denied';
  SuccessStatus = 'ok';
  ErrorStatus = 'error';
var
  i, j: integer; SQLTB: TSQLite3Statement;
  XMLDoc: IXMLDocument;
  XMLNode: IXMLNode;
  RequestDocument: string;

  AuthDeviceID: string;
begin
  CoInitialize(nil);

  if (AllowAnyIPs = false) and (Pos(AThread.Connection.Socket.Binding.PeerIP, AllowedIPs.Text) = 0) then begin CoUninitialize; Exit; end;

  AResponseInfo.CustomHeaders.Add('Access-Control-Allow-Origin: *'); // �������� ������������ ���������

  AuthDeviceID:='';
  for i:=0 to ARequestInfo.Params.Count - 1 do begin
    if AnsiLowerCase(ARequestInfo.Params.Names[i]) = 'id' then
      AuthDeviceID:=ARequestInfo.Params.ValueFromIndex[i];
  end;

  // �����������
  if (AuthDeviceID <> '') and (ARequestInfo.Document = '/api/auth') then begin

    if Pos(AuthDeviceID, AuthorizedDevices.Text) = 0 then begin

      //���� ���������� ����� ��������� ���������
      if BlockReqNewDevs = false then begin
        case MessageBox(Handle, PChar(Format(IDS_DEV_SYNC_CONFIRM, [AuthDeviceID])), PChar(Caption), 35) of
          6: if Pos(AuthDeviceID, AuthorizedDevices.Text) = 0 then begin
                AuthorizedDevices.Add(AuthDeviceID);
                AResponseInfo.ContentText:=AuthorizationSuccessfulStatus;

                SQLDB.Execute('CREATE TABLE IF NOT EXISTS Actions_' + AuthDeviceID + ' (Action TEXT, ID TIMESTAMP, Note TEXT, DateTime TIMESTAMP)');

            end;
          7: AResponseInfo.ContentText:=AuthorizationDeniedStatus;
        end;

      // ���� ���������� ����� ��������� ��������
      end else
        AResponseInfo.ContentText:=AuthorizationDeniedStatus;


    end else // �������� �����������
      AResponseInfo.ContentText:=AuthorizationSuccessfulStatus;

    RequestDocument:='none';
  end;

  // ����� ��������
  if (AuthDeviceID <> '') and (ARequestInfo.Document = '/api/actions') then begin

    if Pos(AuthDeviceID + #13#10, AuthorizedDevices.Text) > 0 then begin
      SQLTB:=SQLDB.Prepare('SELECT * FROM Actions_' + AuthDeviceID);
      try
        AResponseInfo.ContentText:='<actions>' + #13#10;
        while SQLTB.Step = SQLITE_ROW do begin
          if SQLTB.ColumnText(0) = 'INSERT' then
            AResponseInfo.ContentText:=AResponseInfo.ContentText + #9 + '<insert id="' + SQLTB.ColumnText(1) + '" datetime="' + SQLTB.ColumnText(3) + '">' + StrToWideCharCodes( CharCodesToStr(SQLTB.ColumnText(2)) ) + '</insert>' + #13#10;

          if SQLTB.ColumnText(0) = 'UPDATE' then
            AResponseInfo.ContentText:=AResponseInfo.ContentText + #9 + '<update id="' + SQLTB.ColumnText(1) + '" datetime="' + SQLTB.ColumnText(3) + '">' + StrToWideCharCodes( CharCodesToStr(SQLTB.ColumnText(2)) ) + '</update>' + #13#10;

          if SQLTB.ColumnText(0) = 'DELETE' then
              AResponseInfo.ContentText:=AResponseInfo.ContentText + #9 + '<delete id="' + SQLTB.ColumnText(1) + '"></delete>' + #13#10;
        end;
      finally
        AResponseInfo.ContentText:=AResponseInfo.ContentText + '</actions>';
        SQLTB.Free;
      end;

    end else
      AResponseInfo.ContentText:=AuthorizationDeniedStatus;

    RequestDocument:='none';
  end;

  // �������� ���������� ��������
  if (AuthDeviceID <> '') and (ARequestInfo.Document = '/api/received') then begin
    if Pos(AuthDeviceID + #13#10, AuthorizedDevices.Text) > 0 then begin
      SQLDB.Execute('DELETE FROM Actions_' + AuthDeviceID);
      AResponseInfo.ContentText:=SuccessStatus;
    end else
      AResponseInfo.ContentText:=AuthorizationDeniedStatus;

    RequestDocument:='none';
  end;

  // ��� �������
  if (AuthDeviceID <> '') and (ARequestInfo.Document = '/api/notes') then begin

    if Pos(AuthDeviceID + #13#10, AuthorizedDevices.Text) > 0 then begin
      SQLTB:=SQLDB.Prepare('SELECT * FROM Notes ORDER BY DateTime DESC');
      try
        AResponseInfo.ContentText:='<notes>' + #13#10;
        while SQLTB.Step = SQLITE_ROW do
          AResponseInfo.ContentText:=AResponseInfo.ContentText + #9 + '<note id="' + SQLTB.ColumnText(0) + '" datetime="' + SQLTB.ColumnText(2) + '">' + StrToWideCharCodes( CharCodesToStr(SQLTB.ColumnText(1)) ) + '</note>' + #13#10;
      finally
        AResponseInfo.ContentText:=AResponseInfo.ContentText + '</notes>';
        SQLTB.Free;
      end;
    end else
      AResponseInfo.ContentText:=AuthorizationDeniedStatus;

    RequestDocument:='none';
  end;

  // �������� ����������
  if ARequestInfo.Document = '/api/connecttest' then begin
    AResponseInfo.ContentText:=SuccessStatus;
    RequestDocument:='none';
  end;

  if (AuthDeviceID <> '') and (Pos(AuthDeviceID, AuthorizedDevices.Text) > 0) and (ARequestInfo.Document = '/api/syncnotes') and (ARequestInfo.Command = 'POST') and (Trim(ARequestInfo.FormParams) <> '') then begin
    // NoteDone(1); // ���������� ������� �������, ��� ���������� ������
    Caption:=AppName + ' - ' + IDS_SYNC;
    Application.Title:=Caption;
    XMLDoc:=TXMLDocument.Create(nil);
    try
      XMLDoc:=LoadXMLData(ARequestInfo.FormParams);
      XMLDoc.Active:=true;
      AResponseInfo.ContentText:=SuccessStatus;
    except;
      AResponseInfo.ContentText:=ErrorStatus;
    end;

    XMLNode:=XMLDoc.DocumentElement;
    for i:=0 to XMLNode.ChildNodes.Count - 1 do
      try
        if (XMLNode.ChildNodes[i].NodeName = 'insert') and (Trim( StrToCharCodes( WideCharCodesToStr(XMLNode.ChildNodes[i].NodeValue) ) ) <> '') then begin
          SQLDB.Execute('INSERT INTO Notes (ID, Note, DateTime) values("' + XMLNode.ChildNodes[i].Attributes['id'] + '", "' + StrToCharCodes( WideCharCodesToStr(XMLNode.ChildNodes[i].NodeValue) ) + '", "' + XMLNode.ChildNodes[i].Attributes['datetime'] + '")');

          // ��������� �������� �� ��� ������� �������������� ���������. �������� ����������� ����� ��� ������������� ���� ��� ������
          for j:=0 to AuthorizedDevices.Count - 1 do
            if (AuthorizedDevices.Strings[j] <> AuthDeviceID) and (SQLDBTableExists('Actions_' + AuthorizedDevices.Strings[j])) then //��������� ��������� ������������ ��������
              SQLDB.Execute('INSERT INTO Actions_' + AuthorizedDevices.Strings[j] + ' (Action, ID, Note, DateTime) values("INSERT", "' + XMLNode.ChildNodes[i].Attributes['id'] + '", "' + StrToCharCodes( WideCharCodesToStr(XMLNode.ChildNodes[i].NodeValue) ) + '", "' + XMLNode.ChildNodes[i].Attributes['datetime'] + '")');
        end;

        if XMLNode.ChildNodes[i].NodeName = 'update' then begin
          SQLDB.Execute('UPDATE Notes SET Note="' + StrToCharCodes( WideCharCodesToStr(XMLNode.ChildNodes[i].NodeValue) ) + '", DateTime="' + XMLNode.ChildNodes[i].Attributes['datetime'] + '" WHERE ID=' + XMLNode.ChildNodes[i].Attributes['id']);

          // ��������� �������� �� ��� ������� �������������� ���������. �������� ����������� ����� ��� ������������� ���� ��� ������
          for j:=0 to AuthorizedDevices.Count - 1 do
           if (AuthorizedDevices.Strings[j] <> AuthDeviceID) and (SQLDBTableExists('Actions_' + AuthorizedDevices.Strings[j])) then //��������� ��������� ������������ ��������
              SQLDB.Execute('INSERT INTO Actions_' + AuthorizedDevices.Strings[j] + ' (Action, ID, Note, DateTime) values("UPDATE", "' + XMLNode.ChildNodes[i].Attributes['id'] + '", "' + StrToCharCodes( WideCharCodesToStr(XMLNode.ChildNodes[i].NodeValue) ) + '", "' + XMLNode.ChildNodes[i].Attributes['datetime'] + '")');
        end;

        if XMLNode.ChildNodes[i].NodeName = 'delete' then begin
          SQLDB.Execute('DELETE FROM Notes WHERE ID=' + XMLNode.ChildNodes[i].Attributes['id']);
          // ��������� �������� �� ��� ��������� ������� �������������� ���������. �������� ����������� ����� ��� ������������� ���� ��� ������
          for j:=0 to AuthorizedDevices.Count - 1 do
            if (AuthorizedDevices.Strings[j] <> AuthDeviceID) and (SQLDBTableExists('Actions_' + AuthorizedDevices.Strings[j])) then //��������� ��������� ������������ ��������
              SQLDB.Execute('INSERT INTO Actions_' +  AuthorizedDevices.Strings[j] + ' (Action, ID) values("DELETE", "' + XMLNode.ChildNodes[i].Attributes['id'] + '")');
        end;
      except
      end;

    // �������� � ���������� �������, ������� ������ ��������� �������� � LoadNotes ����������� �����.
    WebView.Navigate(ExtractFilePath(ParamStr(0)) + 'style\main.html');

    Caption:=AppName;
    Application.Title:=Caption;
    XMLDoc.Active:=false;
    RequestDocument:='none';
  end;

  if (RequestDocument <> 'none') then begin
    RequestDocument:=ExtractFilePath(ParamStr(0)) + '\webapp' + StringReplace(ARequestInfo.Document, '/', '\', [rfReplaceAll]);
    RequestDocument:=StringReplace(RequestDocument, '\\', '\', [rfReplaceAll]);

    if ARequestInfo.Document = '/webapp' then //�� webapp ������ ������� ����
      RequestDocument:=ExtractFilePath(ParamStr(0)) + 'webapp\main.html';

    if FileExists(RequestDocument) then begin
      AResponseInfo.ContentType:=IdHTTPServer.MIMETable.GetDefaultFileExt(RequestDocument);

    if ARequestInfo.Document = '/app.manifest' then
      AResponseInfo.ContentType:='text/cache-manifest';

      IdHTTPServer.ServeFile(AThread, AResponseinfo, RequestDocument);
    end else
      AResponseInfo.ContentText:=ErrorStatus;
  end;

  CoUninitialize;
end;

procedure TMain.PasteBtnClick(Sender: TObject);
begin
  keybd_event(VK_CONTROL, MapVirtualKey(VK_CONTROL, 0), 0, 0);
  keybd_event(Ord('V'), MapVirtualKey(Ord('V'), 0), 0, 0);
  keybd_event(Ord('V'), MapVirtualKey(Ord('V'), 0), KEYEVENTF_KEYUP, 0);
  keybd_event(VK_CONTROL, MapVirtualKey(VK_CONTROL, 0), KEYEVENTF_KEYUP, 0)
end;

procedure TMain.CopyBtnClick(Sender: TObject);
begin
  keybd_event(VK_CONTROL, MapVirtualKey(VK_CONTROL, 0), 0, 0);
  keybd_event(Ord('C'), MapVirtualKey(Ord('C'), 0), 0, 0);
  keybd_event(Ord('C'), MapVirtualKey(Ord('C'), 0), KEYEVENTF_KEYUP, 0);
  keybd_event(VK_CONTROL, MapVirtualKey(VK_CONTROL, 0), KEYEVENTF_KEYUP, 0)
end;

procedure TMain.CutBtnClick(Sender: TObject);
begin
  keybd_event(VK_CONTROL, MapVirtualKey(VK_CONTROL, 0), 0, 0);
  keybd_event(Ord('X'), MapVirtualKey(Ord('X'), 0), 0, 0);
  keybd_event(Ord('X'), MapVirtualKey(Ord('X'), 0), KEYEVENTF_KEYUP, 0);
  keybd_event(VK_CONTROL, MapVirtualKey(VK_CONTROL, 0), KEYEVENTF_KEYUP, 0)
end;

procedure TMain.AddStyle(FileName: string);
var
  HTMLDocument: IHTMLDocument2;
  StyleSheet: IHTMLStyleSheet;
  StyleSheetIndex: integer;
  StyleFile: TStringList;
begin
  if not FileExists(FileName) then Exit;
  StyleFile:=TStringList.Create;
  StyleFile.LoadFromFile(FileName);
  HTMLDocument:=WebView.Document as IHTMLDocument2;
  StyleSheetIndex:=HTMLDocument.styleSheets.length;
  if StyleSheetIndex > 31 then
    raise Exception.Create('Already have the maximum amount of CSS stylesheets');
  StyleSheet:=HTMLDocument.createStyleSheet('', StyleSheetIndex);
  StyleSheet.cssText:=StyleFile.Text;
  StyleFile.Free;
end;

procedure TMain.ExportNotes(FileName: string);
var
  i: integer; SQLTB: TSQLite3Statement; Notes: TStringList;
begin
  Notes:=TStringList.Create;
  SQLTB:=SQLDB.Prepare('SELECT * FROM Notes ORDER BY DateTime DESC');
  try
    while SQLTB.Step = SQLITE_ROW do
      Notes.Text:=Notes.Text + DateTimeToStr(UNIXToDateTime(StrToInt64(SQLTB.ColumnText(2)))) + #9 + SQLTB.ColumnText(2) + #9 + StringReplace( CharCodesToStr(SQLTB.ColumnText(1)), #10, ' \n ', [rfReplaceAll]) + #13#10;
  finally
    SQLTB.Free;
  end;
  Notes.SaveToFile(FileName);
  Notes.Free;
end;

procedure TMain.ImportNotes(FileName: string);
var
  Notes: TStringList;
  i: integer;
  ImportNote, ImportNoteDateTime, ImportNoteText: string;
begin
  if not FileExists(FileName) then Exit;
  Notes:=TStringList.Create;
  Notes.LoadFromFile(FileName);

  for i:=Notes.Count - 1 downto 0 do begin
    ImportNote:=Notes.Strings[i];
    Delete(ImportNote, 1, Pos(#9, ImportNote));
    if Pos(#9, ImportNote) > 0 then begin
      ImportNoteDateTime:=Copy(ImportNote, 1, Pos(#9, ImportNote) - 1);
      Delete(ImportNote, 1, Pos(#9, ImportNote));
      ImportNoteText:=StringReplace(ImportNote, ' \n ', #10, [rfReplaceAll]);
    end;

    if (Trim(ImportNoteDateTime) <> '') and (Trim(ImportNoteText) <> '') then
      SQLDB.Execute('INSERT INTO Notes (ID, Note, DateTime) values("' + ImportNoteDateTime + '", "' + StrToCharCodes(ImportNoteText) + '", "' + ImportNoteDateTime + '")');
  end;

  Notes.Free;
end;

initialization
 OleInitialize(nil);

finalization
 OleUninitialize;

end.

