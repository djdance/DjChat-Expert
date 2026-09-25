unit uChatFrm;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, Vcl.Graphics, Vcl.Controls,
  Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, System.JSON, IOUtils, Vcl.ExtCtrls,
  System.UITypes, System.IniFiles,Vcl.WinXCtrls,Winapi.Messages,
  IdBaseComponent, IdComponent, IdTCPConnection, IdTCPClient, IdHTTP,
  IdGlobal, IdCoderMIME,//test for utf8 post
  System.StrUtils,System.DateUtils,
  Vcl.ComCtrls,  System.Generics.Collections,System.Math, IdIOHandler,
  IdIOHandlerSocket, IdIOHandlerStack, System.Actions, Vcl.ActnList;

const
  cAttachBoundary = '--== Attached entire code file ==--';

type
  TUIState = (stReady, stLoadingModels, stBusy);
  TChatForm = class(TForm)
    AskPanel: TPanel;
    btnSend: TButton;
    QuestionMemo: TMemo;
    Splitter1: TSplitter;
    Panel1: TPanel;
    AttachFileCheckBox: TCheckBox;
    Label1: TLabel;
    PasteButton: TButton;
    ClearChatButton: TButton;
    PrefsButton: TButton;
    ActivityIndicator1: TActivityIndicator;
    OptionsPanel: TPanel;
    TokenUsageProgressBar: TProgressBar;
    Label2: TLabel;
    OllamaTestButton: TButton;
    Label3: TLabel;
    SummaryMemo: TMemo;
    SummaryMemoShowButton: TButton;
    Panel2: TPanel;
    Label5: TLabel;
    OllamaSyspromptEdit: TEdit;
    Panel3: TPanel;
    WarnLabel: TLabel;
    ModelContextLimitEdit: TEdit;
    ActionList1: TActionList;
    Action1: TAction;
    Panel4: TPanel;
    OpenRouterApiKeyEdit: TEdit;
    Button1: TButton;
    OllamaPingButton: TButton;
    StatusBar1: TStatusBar;
    Panel5: TPanel;
    ModelComboBox: TComboBox;
    ModelCommentEdit: TEdit;
    modelUrlEdit: TComboBox;
    AnswerRichEdit: TRichEdit;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure QuestionMemoChange(Sender: TObject);
    procedure btnSendClick(Sender: TObject);
    procedure PasteButtonClick(Sender: TObject);
    procedure ClearChatButtonClick(Sender: TObject);
    procedure PrefsButtonClick(Sender: TObject);
    procedure OllamaTestButtonClick(Sender: TObject);
    procedure ModelComboBoxDropDown(Sender: TObject);
    procedure ModelComboBoxCloseUp(Sender: TObject);
    procedure SummaryMemoShowButtonClick(Sender: TObject);
    procedure QuestionMemoKeyPress(Sender: TObject; var Key: Char);
    procedure Action1Execute(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure Button1Click(Sender: TObject);
    procedure OllamaPingButtonClick(Sender: TObject);
    procedure AttachFileCheckBoxClick(Sender: TObject);
    procedure ModelCommentEditChange(Sender: TObject);
    procedure modelUrlEditChange(Sender: TObject);
  private
    FIsActivated: Boolean; // Флаг для первого запуска
    FHistory: TJSONArray;
    FActiveHttp:TIdHttp;
    FFileName: string;
    selectedText,selectedFile:string;
    mode:integer;
    FOldActivityIndicatorProc: TWndMethod;
    FModelContextLimit: Integer; // Хранит лимит контекста (в токенах) для текущей модели
    FRequestTimer: TTimer;
    FRequestStartTime: TDateTime;
    FModelStats: TDictionary<string, string>; // model -> 'date|comment|maxSec'
    FCurrentRequestStart: TDateTime;          // если ещё нет — используйте FRequestStartTime
    FUpdatingComment: Boolean;                // защита от рекурсии при программной установке
    procedure SetStatField(const Model, Field: string; const Value: string);
    procedure UpdateModelCommentFromStats;
    procedure FormatRichEdit(Rich: TRichEdit);
    procedure updateOllamaContextLimit;
    procedure processCallFromMenu;
    procedure LoadHistoryFromFile;
    procedure SaveHistoryToFile;
    procedure SummarizeHistoryIfNeeded;
    //procedure getModelContextLimitIfNeed;
    procedure DisableUI(disable:TUIState = stBusy);
    procedure ActivityIndicatorWindowProc(var Message: TMessage);
    function GetPost2Ollama(const ABaseUrl: string; AJsonToSend: TJSONObject; const timeout: integer): TJSONObject;
    procedure ChatWithOllama(mode:String = 'default');
    procedure RequestTimerTimer(Sender: TObject);
  public
    procedure PrepareForUnload;
  end;

var
  ChatForm: TChatForm;

procedure ShowChatForm(const selectedText,selectedFile: string; mode:integer);

implementation

{$R *.dfm}

uses uMiniChatExpert;

procedure ShowChatForm(const selectedText,selectedFile: string; mode:integer);
begin
  var firstStart:=not Assigned(ChatForm);

  //test! if firstStart then ChatForm := TChatForm.Create(Application);
  if firstStart then ChatForm := TChatForm.Create(nil); //nil чтобы не падало при Uninstall

  ChatForm.selectedText:=selectedText;
  ChatForm.selectedFile:=selectedFile;
  ChatForm.mode:=mode;
  ChatForm.Show;
  TThread.CreateAnonymousThread(procedure begin
    if firstStart then sleep(1500); //wait while form is ready
    TThread.Synchronize(nil,procedure begin
      ChatForm.processCallFromMenu;
    end);
  end).Start;
end;
procedure TChatForm.FormActivate(Sender: TObject);
begin
  // Если форма активируется первый раз (сразу после создания), пропускаем, так как данные уже переданы через ShowChatForm.
  if not FIsActivated then begin
    FIsActivated := True;
    Exit;
  end;
  // Вызываем функцию из uMiniChatExpert для получения актуальных данных
  MiniChatExpert.GetEditorSelection(selectedText, selectedFile);
  processCallFromMenu;
end;
procedure TChatForm.FormCreate(Sender: TObject);
var
  AppDataPath: string;
begin
  FIsActivated := False;
  FHistory := TJSONArray.Create;
  FModelStats := TDictionary<string, string>.Create;

  FRequestTimer := TTimer.Create(Self);
  FRequestTimer.Interval := 1000; // Обновление каждую секунду
  FRequestTimer.Enabled := False;
  FRequestTimer.OnTimer := RequestTimerTimer;
  StatusBar1.Panels[0].Text := 'Ready';

  {
  The default context length in Ollama is 4096 tokens. https://docs.ollama.com/context-length
  Tasks which require large context like web search, agents, and coding tools should be set to at least 32000 tokens.
  Change the slider in the Ollama app under settings to your desired context length.
  }
  FModelContextLimit := 4096;
  TokenUsageProgressBar.Max:=FModelContextLimit;

  // Формируем путь в AppData
  AppDataPath := TPath.Combine(TPath.GetHomePath, 'DjChatExpert');
  ForceDirectories(AppDataPath);
  FFileName := TPath.Combine(AppDataPath, 'config.json');
  SummaryMemo.Lines.Add('Settings in '+FFileName);

  // Перехватываем сообщения индикатора, чтобы работал клик==отмена
  FOldActivityIndicatorProc := ActivityIndicator1.WindowProc;
  ActivityIndicator1.WindowProc := ActivityIndicatorWindowProc;

  // Запускаем в отдельном потоке чтобы форма коректно спозиционировалась
  TThread.CreateAnonymousThread(procedure begin
    TThread.Synchronize(nil,procedure begin
      LoadHistoryFromFile;
    end);
  end).Start;

end;
procedure TChatForm.FormDestroy(Sender: TObject);
begin
  FreeAndNil(FHistory);
  FreeAndNil(FModelStats);
  ChatForm := nil;
end;
procedure TChatForm.PrepareForUnload;
begin
  DisableUI(stReady);
  if Assigned(FActiveHttp) then begin
    FActiveHttp.Disconnect;
    FreeAndNil(FActiveHttp);
  end;
  FRequestTimer.Enabled := False;
  sleep(300);
end;
//быстрый вызов из Tools в поисках юнита.
procedure TChatForm.processCallFromMenu;
begin
  PasteButton.Enabled:=selectedText<>'';
  AttachFileCheckBox.Enabled:=selectedFile<>'';
  AttachFileCheckBox.Caption:='Entire file '+ExtractFileName(selectedFile);
  QuestionMemoChange(nil);
  if QuestionMemo.CanFocus then QuestionMemo.SetFocus;
  if mode=2 then begin
     QuestionMemo.text:= 'Programming in modern Delphi. Reply ONLY with the unit name that contains: '+sLineBreak + selectedText;
     btnSendClick(nil);
     QuestionMemo.text:='';
     mode:=0;
  end;
end;


//юзерское окно чата
procedure TChatForm.QuestionMemoChange(Sender: TObject);
begin
  btnSend.Enabled:=trim(QuestionMemo.Text)<>'';
end;
procedure TChatForm.QuestionMemoKeyPress(Sender: TObject; var Key: Char);
begin
  //it works! if Key = #10 then Key := #0;
end;
procedure TChatForm.Action1Execute(Sender: TObject);
begin
  TThread.CreateAnonymousThread(procedure begin Sleep(50);TThread.Synchronize(nil, procedure begin btnSend.Click; end); end).Start;
end;
procedure TChatForm.PasteButtonClick(Sender: TObject);
begin
  if selectedText='' then exit;
  QuestionMemo.Text:=QuestionMemo.Text+sLineBreak+sLineBreak+selectedText;
  //if AskPanel.Height<height div 2 then AskPanel.Height:=height div 2;
end;
procedure TChatForm.PrefsButtonClick(Sender: TObject);
begin
  OptionsPanel.Visible:=not OptionsPanel.Visible;
  if not OptionsPanel.Visible then SaveHistoryToFile
end;
procedure TChatForm.ClearChatButtonClick(Sender: TObject);
begin
  if MessageDlg('Clear chat history?', mtConfirmation, [mbYes, mbNo], 0) = mrYes then begin
    AnswerRichEdit.Lines.Clear;
    FreeAndNil(FHistory);
    FHistory := TJSONArray.Create;
    SaveHistoryToFile;
  end;
end;



//обращения по сети
procedure TChatForm.ActivityIndicatorWindowProc(var Message: TMessage);
begin
  if (Message.Msg = WM_LBUTTONUP) then begin
    //QuestionMemo.Text:=QuestionMemo.Text+sLineBreak+ 'TChatForm.ActivityIndicatorWindowProc, Assigned(FActiveHttp)='+booltostr(Assigned(FActiveHttp))+', FActiveHttp=nil='+booltostr(FActiveHttp=nil)+' '+datetimetostr(now);
    if Assigned(FActiveHttp) then GetPost2Ollama('',nil,0);//break connection
  end;
  // вызываем старую процедуру, чтобы индикатор крутился
  if Assigned(FOldActivityIndicatorProc) then FOldActivityIndicatorProc(Message);
end;
procedure TChatForm.AttachFileCheckBoxClick(Sender: TObject);
var CurrText, CurrFile: string;
begin
  if not AttachFileCheckBox.Checked then begin
    WarnLabel.Caption := '';
    Exit;
  end;
  var CurrChars := 0;
  var LastIdx := 0;
  for var I := FHistory.Count - 1 downto 0 do if TJSONObject(FHistory.Items[I]).GetValue('role').Value = 'system' then begin
    LastIdx := I; Break;
  end;
  for var I := LastIdx to FHistory.Count - 1 do begin
    var Item := TJSONObject(FHistory.Items[I]);
    if Item.TryGetValue('content', CurrText) then Inc(CurrChars, Length(CurrText));
    if Item.TryGetValue('file', CurrFile) and (CurrFile <> '') and FileExists(CurrFile) then Inc(CurrChars, TFile.GetSize(CurrFile));
  end;
  var FileChars := 0;
  if FileExists(selectedFile) then FileChars := TFile.GetSize(selectedFile);
  var TotalTokens:Int64 := (CurrChars + FileChars) div 4;
  if TotalTokens > FModelContextLimit then
    WarnLabel.Caption := Format('Warning: will attach ~%d tokens > limit %d', [TotalTokens, FModelContextLimit])
  else
    WarnLabel.Caption := '';
end;

procedure TChatForm.OllamaPingButtonClick(Sender: TObject);
begin
  StatusBar1.Panels[0].Text := 'Pinging AI...';
  QuestionMemo.text:= 'This is just a test. Just answer YES if you received this.';
  btnSendClick(nil);
  QuestionMemo.text:='';
end;
procedure TChatForm.OllamaTestButtonClick(Sender: TObject);
var
  JsonObj: TJSONObject;
  DummyValue: TJSONValue;
  ErrVal: TJSONValue;
  IsOpenRouter: Boolean;
  TestUrl: string;
  ErrMsg: string;
begin
  //Внимание, опенроутер не доделан и не проверн, потому что заблокирован в РФ
  IsOpenRouter := string(modelUrlEdit.Text).Contains('openrouter.ai');
  if IsOpenRouter then begin
    TestUrl := string(modelUrlEdit.Text).TrimEnd(['/']);
    if TestUrl.Contains('/v1') then
      TestUrl := TestUrl + '/models'
    else
      TestUrl := TestUrl + '/api/v1/models';
  end else
    TestUrl := string(modelUrlEdit.Text).TrimEnd(['/']) + '/api/tags';
  StatusBar1.Panels[0].Text := 'Testing connection... '+TestUrl;

  JsonObj := GetPost2Ollama(TestUrl, nil, 1000);
  try
    if Assigned(JsonObj) then begin
      if JsonObj.TryGetValue('error', ErrVal) then begin
        if IsOpenRouter and (ErrVal is TJSONObject) then
          // У OpenRouter ошибка - это объект {"error": {"message": "..."}}
          ErrMsg := (ErrVal as TJSONObject).GetValue<string>('message', ErrVal.ToString)
        else
          // У Ollama ошибка - это просто строка
          ErrMsg := ErrVal.Value;
        ShowMessage('Test error: ' + ErrMsg);
      end else begin
        if IsOpenRouter then begin
          // У OpenRouter (OpenAI format) модели лежат в массиве "data"
          if JsonObj.TryGetValue('data', DummyValue) then
            ShowMessage('OpenRouter API test OK!')
          else
            ShowMessage('OpenRouter test failed (JSON valid, but no "data" array)');
        end else begin
          // У Ollama модели лежат в массиве "models"
          if JsonObj.TryGetValue('models', DummyValue) then
            ShowMessage('Ollama test OK!')
          else
            ShowMessage('Ollama test failed (JSON valid, but no "models" array)');
        end;
      end;
    end
    else
      ShowMessage('Test failed (Connection or JSON parse error)');
  finally
    if Assigned(JsonObj) then JsonObj.Free;
  end;
end;

procedure TChatForm.modelUrlEditChange(Sender: TObject);
begin
  OpenRouterApiKeyEdit.Visible:=string(modelUrlEdit.text).Contains('openrouter.ai')
end;

procedure TChatForm.DisableUI(disable:TUIState = stBusy);
begin
  TThread.Synchronize(nil,procedure begin
    if ActivityIndicator1.Animate=(disable>stReady) then exit;//already was toggled
    ActivityIndicator1.Animate:=disable>stReady;
    QuestionMemo.ReadOnly:=disable>stReady;
    PrefsButton.Enabled:=disable=stReady;
    OllamaTestButton.Enabled:=disable=stReady;
    OllamaPingButton.Enabled:=disable=stReady;
    btnSend.Enabled:=disable=stReady;
    //also...
    ClearChatButton.Enabled:=disable=stReady;
    ModelComboBox.Enabled:=disable<stBusy; //чтобы не схлопывалось в момент открытия
    modelUrlEdit.Enabled:=disable=stReady;
    ModelCommentEdit.Enabled:=disable=stReady;
  end);
end;
procedure TChatForm.RequestTimerTimer(Sender: TObject);
var
  Secs: Integer;
begin
  Secs := SecondsBetween(Now, FRequestStartTime);
  if Secs < 60 then
    StatusBar1.Panels[0].Text := 'Waiting for response... ' + IntToStr(Secs) + 's'
  else
    StatusBar1.Panels[0].Text := 'Loading model... ' + IntToStr(Secs div 60) + 'm ' + IntToStr(Secs mod 60) + 's';
end;
procedure TChatForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if ActivityIndicator1.Animate then canclose:=false;
end;

//выбор модели
function ParseStat(const S: string; out Date, Comment, MaxSec: string): Boolean;
var P1, P2: Integer;
begin
  Date := ''; Comment := ''; MaxSec := '';
  P1 := Pos('|', S);
  if P1 = 0 then Exit(False);
  P2 := PosEx('|', S, P1 + 1);
  if P2 = 0 then Exit(False);
  Date := Copy(S, 1, P1 - 1);
  Comment := Copy(S, P1 + 1, P2 - P1 - 1);
  MaxSec := Copy(S, P2 + 1, MaxInt);
  Result := True;
end;
function BuildStat(const Date, Comment, MaxSec: string): string;
begin
  Result := Date + '|' + Comment + '|' + MaxSec;
end;
function GetModelKey(const ComboText: string): string;
var  P: Integer;
begin
  P := Pos('--', ComboText);
  Result := Trim(if P>0 then Copy(ComboText, 1, P-1) else ComboText);
end;
procedure TChatForm.ModelComboBoxCloseUp(Sender: TObject);
begin
  TThread.ForceQueue(nil, procedure begin
    //SummaryMemo.Lines.add('ModelComboBoxCloseUp '+ModelComboBox.Text);//debug
    SetStatField(GetModelKey(ModelComboBox.Text), 'date', FormatDateTime('yyyy-mm-dd', Date));
    UpdateModelCommentFromStats;
    SaveHistoryToFile;
  end);
end;
procedure TChatForm.ModelComboBoxDropDown(Sender: TObject);
var
  JsonObj: TJSONObject;
  ModelsArr: TJSONArray;
  ModelItem,NameVal: TJSONValue;
  StatStr, D, C, M: string;
begin
  DisableUI(stLoadingModels); //задисаблим все кроме комбобокса
  JsonObj := GetPost2Ollama(modelUrlEdit.Text + '/api/tags', nil,2000); // Таймаут 2 сек
  try
    if Assigned(JsonObj) and JsonObj.TryGetValue('models', ModelsArr) then begin
      ModelComboBox.Items.BeginUpdate;
      try
        ModelComboBox.Items.Clear;
        for var Pass := 0 to 1 do
          for var I := 0 to ModelsArr.Count - 1 do
            if (ModelsArr.Items[I] is TJSONObject) and TJSONObject(ModelsArr.Items[I]).TryGetValue('name', NameVal) then
              if LowerCase(NameVal.Value).EndsWith('cloud') = (Pass = 0) then begin
                D:=''; C:=''; M:='';
                if FModelStats.TryGetValue(NameVal.Value, StatStr) then ParseStat(StatStr, D, C, M);
                ModelComboBox.Items.Add(NameVal.Value + ifthen(C.IsEmpty and M.IsEmpty,'',' -- ' + C+' (answers in '+M+'s, measured '+D+')'));
              end;
      finally
        ModelComboBox.Items.EndUpdate;
      end;
    end;
  finally
    if Assigned(JsonObj) then JsonObj.Free;
  end;
  //SummaryMemo.Lines.AddStrings(ModelComboBox.Items);//debug
end;
procedure TChatForm.SetStatField(const Model, Field: string; const Value: string);
var  S, D, C, M: string;
begin
  //SummaryMemo.Lines.add('SetStatField('+model+', '+field+', '+value+')');//debug
  if Model = '' then Exit;
  if not FModelStats.TryGetValue(Model, S) then S := BuildStat(FormatDateTime('yyyy-mm-dd', Date), '', '0');
  ParseStat(S, D, C, M);
  //SummaryMemo.Lines.add('SetStatField: ParseStat => '+D+','+C+','+M+')');//debug
  if SameText(Field, 'date') then D := Value
  else if SameText(Field, 'comment') then C := Value
  else if SameText(Field, 'maxsec') then M := Value;
  //SummaryMemo.Lines.add('SetStatField: save '+D+','+C+','+M+')');//debug
  FModelStats.AddOrSetValue(Model, BuildStat(D, C, M));
end;
procedure TChatForm.UpdateModelCommentFromStats;
var RealModel,S, D, C, M: string;
begin
  FUpdatingComment := True;
  try
    RealModel := GetModelKey(ModelComboBox.Text);
    if FModelStats.TryGetValue(RealModel, S) and ParseStat(S, D, C, M) then begin
      ModelCommentEdit.Text := C;
      //SummaryMemo.Lines.add('UpdateModelCommentFromStats: ModelCommentEdit:='+C);//debug
    end else begin
      ModelCommentEdit.Text := '';
      //SummaryMemo.Lines.add('UpdateModelCommentFromStats: ModelCommentEdit removed');//debug
    end;
  finally
    FUpdatingComment := False;
  end;
end;
procedure TChatForm.ModelCommentEditChange(Sender: TObject);
begin
  if FUpdatingComment then Exit;
  if ModelComboBox.Text = '' then Exit;
  SetStatField(GetModelKey(ModelComboBox.Text), 'comment', ModelCommentEdit.Text);
  SaveHistoryToFile;
end;






//конфиг и история
procedure TChatForm.LoadHistoryFromFile;
var
  MainObj: TJSONObject;
  HistoryArr: TJSONArray;
  SettingsObj: TJSONObject;
  I: Integer;
  Item: TJSONValue;
  texxt: string;
  Role, Text, Filename: string;
begin
  if not FileExists(FFileName) then Exit;
  try
    MainObj := TJSONObject.ParseJSONValue(TFile.ReadAllText(FFileName, TEncoding.UTF8)) as TJSONObject;
    if not Assigned(MainObj) then Exit;
    try
      // 1. Загружаем Настройки
      if MainObj.TryGetValue<TJSONObject>('Settings', SettingsObj) then begin
        var L, T, W, H: Integer; // Загружаем все 4 параметра в временные переменные, чтобы не дергать форму
        if SettingsObj.TryGetValue('Left', L) and SettingsObj.TryGetValue('Top', T) then
          if SettingsObj.TryGetValue('Width', W) and SettingsObj.TryGetValue('Height', H) then SetBounds(L, T, W, H);
        if SettingsObj.TryGetValue('WindowState', I) then WindowState := TWindowState(I);
        if SettingsObj.TryGetValue('OllamaUrl', texxt) then modelUrlEdit.text:=texxt else modelUrlEdit.text:='http://localhost:11434';
        if SettingsObj.TryGetValue('OllamaKey', texxt) then OpenRouterApiKeyEdit.text:=texxt else OpenRouterApiKeyEdit.text:='';
        if SettingsObj.TryGetValue('OllamaModel', texxt) then ModelComboBox.Text := texxt;
        if SettingsObj.TryGetValue('OllamaContextLimit', texxt) then ModelContextLimitEdit.Text := texxt;
        if not SettingsObj.TryGetValue('OllamaSysprompt', texxt) then texxt:='You are a senior Delphi (Object Pascal) developer. Use ONLY Delphi syntax (VCL/FMX). Write modern efficient code: compact style, inline vars, ternary operators. One-liners preferred.';
        OllamaSyspromptEdit.text:= texxt;
        //статы
        var StatsObj := TJSONObject.Create;
        if SettingsObj.TryGetValue<TJSONObject>('ModelStats', StatsObj) then begin
          FModelStats.Clear;
          for var Pair in StatsObj do
            FModelStats.AddOrSetValue(Pair.JsonString.Value, Pair.JsonValue.Value);
        end;
      end;
      updateOllamaContextLimit;
      UpdateModelCommentFromStats;

      // 2. Загружаем Историю
      if MainObj.TryGetValue<TJSONArray>('Messages', HistoryArr) then begin
        // Чистим текущий массив и добавляем новое
        for I := FHistory.Count - 1 downto 0 do FHistory.Remove(I).free;
        for I := 0 to HistoryArr.Count - 1 do begin
          Item := HistoryArr.Items[I];
          if Item is TJSONObject then FHistory.AddElement(Item.Clone as TJSONObject);
        end;
        // Отображаем в Memo
        texxt := '';
        for I := 0 to FHistory.Count - 1 do begin
          Item := FHistory.Items[I];
          if Item is TJSONObject then begin
            var JObj := TJSONObject(Item);
            JObj.TryGetValue('role', Role);
            JObj.TryGetValue('content', Text);
            JObj.TryGetValue('file', Filename);
            if Role<>'system' then begin //суммаризацию юзеру не выводим
              texxt := texxt + Role + ':'+sLineBreak + trim(Text) + sLineBreak;
              //эти две строки выводились всегда, поправлено, тестируем.... 25092026
              if Filename<>'' then texxt := texxt + cAttachBoundary + ' ' + ExtractFileName(Filename) + sLineBreak;
              texxt := texxt + sLineBreak;
            end;
          end;
        end;
        AnswerRichEdit.Lines.Text := texxt;
        AnswerRichEdit.SelStart := Length(AnswerRichEdit.Lines.Text); AnswerRichEdit.SelLength := 0;//поставим курсор в конец
        FormatRichEdit(AnswerRichEdit);

      end;
    finally
      MainObj.Free;
    end;
  except
    // Если файл битый, стартуем с чистого листа. Очистка FHistory на всякий случай
    for I := FHistory.Count - 1 downto 0 do FHistory.Remove(I).free;
  end;
end;
procedure TChatForm.SaveHistoryToFile;
var
  MainObj: TJSONObject;
  SettingsObj: TJSONObject;
begin
  if FFileName = '' then Exit;
  MainObj := TJSONObject.Create;
  try
    // 1. Настройки
    SettingsObj := TJSONObject.Create;
    try
      SettingsObj.AddPair('OllamaUrl', modelUrlEdit.Text);
      SettingsObj.AddPair('OllamaKey', OpenRouterApiKeyEdit.Text);
      SettingsObj.AddPair('OllamaModel', ModelComboBox.Text);
      updateOllamaContextLimit;
      SettingsObj.AddPair('OllamaContextLimit', ModelContextLimitEdit.Text);
      if WindowState <> wsMinimized then begin
        SettingsObj.AddPair('Left', TJSONNumber.Create(Left));
        SettingsObj.AddPair('Top', TJSONNumber.Create(Top));
        SettingsObj.AddPair('Width', TJSONNumber.Create(Width));
        SettingsObj.AddPair('Height', TJSONNumber.Create(Height));
        SettingsObj.AddPair('WindowState', TJSONNumber.Create(Integer(WindowState)));
      end;
      SettingsObj.AddPair('OllamaSysprompt', OllamaSyspromptEdit.Text);
      //статы по моделям
      var StatsObj := TJSONObject.Create;
      for var Pair in FModelStats do StatsObj.AddPair(Pair.Key, Pair.Value);
      SettingsObj.AddPair('ModelStats', StatsObj);
      //пишем в шапку конфига
      MainObj.AddPair('Settings', SettingsObj);
    except
      SettingsObj.Free;
      raise;
    end;
    // 2. История
    MainObj.AddPair('Messages', FHistory.Clone as TJSONArray);
    TFile.WriteAllText(FFileName, MainObj.ToString,TEncoding.UTF8); //кодировку вроде необязательно, но оставим для симметрии.
  finally
    MainObj.Free;
  end;
end;
procedure TChatForm.SummarizeHistoryIfNeeded;
  function GetContextSize: Integer;
  var CurrText, CurrFile: string;
  begin
    Result := 0;
    var LastIdx := 0;
    for var I := FHistory.Count - 1 downto 0 do if TJSONObject(FHistory.Items[I]).GetValue('role').Value = 'system' then begin
      LastIdx := I;
      Break;
    end;
    var ProcessedFiles := TStringList.Create;
    try
      ProcessedFiles.Duplicates := TDuplicates.dupIgnore;
      ProcessedFiles.CaseSensitive := False;
      for var I := LastIdx to FHistory.Count - 1 do begin
        var Item := TJSONObject(FHistory.Items[I]);
        if Item.TryGetValue('content', CurrText) then Result := Result + Length(CurrText);
        if Item.TryGetValue('file', CurrFile) and (CurrFile <> '') then if FileExists(CurrFile) then ProcessedFiles.Add(CurrFile);
      end;
      for var FileName in ProcessedFiles do Result := Result + TFile.GetSize(FileName);
    finally
      ProcessedFiles.Free;
    end;
  end;
begin
  var CharCount := GetContextSize;
  TThread.Synchronize(nil, procedure begin
    TokenUsageProgressBar.Position := CharCount div 4;
  end);
  if CharCount > (FModelContextLimit - 200) * 4 then begin
    ChatWithOllama('summarize');
    // Пересчитываем размер после сжатия и обновляем UI
    CharCount := GetContextSize;
    TThread.Synchronize(nil, procedure begin
      TokenUsageProgressBar.Position := CharCount div 4;
    end);
  end;
end;


function TChatForm.GetPost2Ollama(const ABaseUrl: string; AJsonToSend: TJSONObject; const timeout: integer): TJSONObject;
var RawString: string;
  ResponseStream: TStringStream;
  JsonStream: TStringStream;
  IsOpenRouter: Boolean;
begin
  Result:=nil;
  if (ABaseUrl = '') or (timeout = 0) then begin // Обработка прерывания (пустой URL или таймаут 0)
    if Assigned(FActiveHttp) then begin
      FActiveHttp.Disconnect;
      FreeAndNil(FActiveHttp);
    end;
    Exit(nil);
  end;
  DisableUI;
  IsOpenRouter := ABaseUrl.Contains('openrouter.ai');
  // таймер статусбара
  FRequestStartTime := Now;
  TThread.Queue(nil, procedure begin
    FRequestTimer.Enabled := True;
    StatusBar1.Panels[0].Text := 'Sending request...';
  end);

  FActiveHttp := TIdHTTP.Create(nil);
  try
    FActiveHttp.ConnectTimeout := timeout;
    FActiveHttp.ReadTimeout := timeout;

    // Отключаем генерацию исключений при HTTP-ошибках (401, 404, 429), Чтобы сервер дал JSON (например, "Invalid API key")
    FActiveHttp.HTTPOptions := FActiveHttp.HTTPOptions + [hoNoProtocolErrorException];

    //необяз.тест.от 500
    FActiveHttp.Request.Accept := 'application/json';
    FActiveHttp.Request.ContentType := 'application/json; charset=utf-8';

    if IsOpenRouter then begin
      // Передаем API ключ. Замените OpenRouterApiKeyEdit на ваш реальный компонент.
      FActiveHttp.Request.CustomHeaders.AddValue('Authorization', 'Bearer ' + OpenRouterApiKeyEdit.Text);
      // Опциональные (но рекомендуемые OpenRouter) заголовки:
      FActiveHttp.Request.CustomHeaders.AddValue('HTTP-Referer', 'djchatexpert');
      FActiveHttp.Request.CustomHeaders.AddValue('X-Title', 'Delphi AI Plugin');
    end;

    if AJsonToSend<>nil then begin
      FActiveHttp.Request.ContentType := 'application/json';
      var JsonString := AJsonToSend.ToString;
      JsonStream := TStringStream.Create(JsonString, TEncoding.UTF8);
      //RawString := FActiveHttp.Post(ABaseUrl, JsonStream);    //так от олламы в 2026 году стала приходить битая кириллица
      //поэтому перекодируем utf8 сами.
      ResponseStream := TStringStream.Create('', TEncoding.UTF8);
      try
        FActiveHttp.Post(ABaseUrl, JsonStream, ResponseStream);
        RawString := ResponseStream.DataString;
      finally
        ResponseStream.Free;
        JsonStream.Free;
      end;
    end else
      RawString := FActiveHttp.Get(ABaseUrl);

    if RawString<>'' then Result := TJSONObject.ParseJSONValue(RawString) as TJSONObject;

    // Если ответ пустой, но код ответа не 200 (например, 502 Bad Gateway)
    if not Assigned(Result) and (FActiveHttp.ResponseCode >= 400) then begin
      var ErrMsg := 'HTTP ' + IntToStr(FActiveHttp.ResponseCode) + ': ' + FActiveHttp.ResponseText;
      // Если сервер вернул текст (например "cuda out of memory"), покажем его!
      if (RawString <> '') and not RawString.StartsWith('{') then ErrMsg := ErrMsg + sLineBreak + 'Server response: ' + RawString;
      if IsOpenRouter then
        Result := TJSONObject.Create.AddPair('error', TJSONObject.Create.AddPair('message', ErrMsg))
      else
        Result := TJSONObject.Create.AddPair('error', ErrMsg);
    end;

  except
    on E: Exception do begin
      // Перехватываем только сетевые исключения (Connection refused, Socket timeout)
      if IsOpenRouter then
        Result := TJSONObject.Create.AddPair('error', TJSONObject.Create.AddPair('message', E.Message))
      else
        Result := TJSONObject.Create.AddPair('error', E.Message);
      TThread.Synchronize(nil, procedure begin
        SummaryMemo.Lines.AddStrings(E.Message);
      end);

    end;
  end;
  FreeAndNil(FActiveHttp);
  DisableUI(stReady);
  // Останавливаем таймер статусбара
  TThread.Queue(nil, procedure begin
    FRequestTimer.Enabled := False;
    StatusBar1.Panels[0].Text := '';
  end);
end;
procedure TChatForm.ChatWithOllama(mode:String = 'default');
var I:integer;
begin
  var IsOpenRouter := string(modelUrlEdit.Text).Contains('openrouter.ai');    // --- АВТОДЕТЕКТИРОВАНИЕ API ---
  var BaseUrl := string(modelUrlEdit.Text).TrimEnd(['/']);
  var EndpointUrl:=if IsOpenRouter then
    BaseUrl + IfThen(BaseUrl.Contains('/v1'), '/chat/completions', '/api/v1/chat/completions')
  else
    BaseUrl + '/api/chat';

  var ReqBody := TJSONObject.Create;
  try
    ReqBody.AddPair('model', GetModelKey(ModelComboBox.Text));
    ReqBody.AddPair('stream', TJSONBool.Create(False));
    if IsOpenRouter then begin
      ReqBody.AddPair('max_tokens', TJSONNumber.Create(4096)); // иначе может обрезать ответ
      ReqBody.AddPair('reasoning', TJSONObject.Create.AddPair('enabled', TJSONBool.Create(False)));
    end else begin
      ReqBody.AddPair('options', TJSONObject.Create.AddPair('num_ctx', TJSONNumber.Create(FModelContextLimit)));
      ReqBody.AddPair('keep_alive', TJSONNumber.Create(-1));
      ReqBody.AddPair('think', TJSONBool.Create(False));
    end;

    var MessagesArray := TJSONArray.Create;
    //чат или суммаризация?
    var CurrentSysPrompt := '';
      if mode = 'summarize' then
        CurrentSysPrompt :=
        'You are a technical conversation archivist for a Delphi development. Analyze the FULL dialogue history and create a concise summary.' + sLineBreak +
        '**OUTPUT 2 SECTIONS:**' + sLineBreak +
        '1.  **Conversation Summary:** In 3-4 lines, capture core topic, problems, solutions, and decisions.' + sLineBreak +
        '2.  **Technical References:**  Bullet list of exact entities mentioned - function/class/variable names, files, components.' + sLineBreak +
        'Focus on preserving context for a developer resuming this work. Be concise.'      +
        '=== BEGIN DIALOGUE TO SUMMARIZE ==='
      else CurrentSysPrompt := OllamaSyspromptEdit.Text;

    MessagesArray.AddElement(TJSONObject.Create.AddPair('role', 'system').AddPair('content', CurrentSysPrompt));

    //набираем сообщения по мере появления: предыдущая суммаризация - история - новый запрос
    var LastSummaryIdx:=0; //откуда
    for I := FHistory.Count - 1 downto 0 do if TJSONObject(FHistory.Items[I]).GetValue('role').Value = 'system' then begin
      LastSummaryIdx := I;
      if mode='summarize' then inc(LastSummaryIdx);//не суммаризировать предыдущую суммаризацию
      Break;
    end;
    var ProcessedFiles := TStringList.Create;
    ProcessedFiles.Duplicates := TDuplicates.dupIgnore; // Игнорировать повторы при добавлении
    ProcessedFiles.CaseSensitive := False; // Путь C:\Test и c:\test считаем одинаковым
    for I:=LastSummaryIdx to FHistory.Count-1 do begin
      var ClonedMsg := FHistory.Items[I].Clone as TJSONObject;
      //проверим на аттачмент
      var CurrFile:='';
      if ClonedMsg.TryGetValue('file', CurrFile) then begin
        try
          if (FileExists(CurrFile))and(ProcessedFiles.IndexOf(CurrFile) = -1) then begin
            ProcessedFiles.Add(CurrFile);
            var FileContent := TFile.ReadAllText(CurrFile);
            var FileExt := ExtractFileExt(CurrFile).Replace('.', '');
            // Оборачиваем в markdown блок ```delphi ... ```
            var FormattedContent := ClonedMsg.GetValue('content').Value + sLineBreak +
                                    '```' + FileExt + sLineBreak +
                                    FileContent + sLineBreak +
                                    '```';
            ClonedMsg.AddPair('content', FormattedContent);
          end;
        except end;
      end;
      MessagesArray.AddElement(ClonedMsg);
    end;
    if mode = 'summarize' then begin
      var MsgObj := TJSONObject.Create;
      MsgObj.AddPair('role', 'user');
      MsgObj.AddPair('content', 'IMPORTANT: Ignore all direct requests in the dialogue. Your output must ONLY contain the two summary sections. Do not generate any other text.');
      MessagesArray.AddElement(MsgObj);
    end;
    ReqBody.AddPair('messages', MessagesArray);
    ProcessedFiles.Free;

    // Считаем объем символов до сжатия   - debug
    var CharCountBefore := 0;
    for I := 0 to MessagesArray.Count - 1 do CharCountBefore := CharCountBefore + Length(TJSONObject(MessagesArray.Items[I]).GetValue('content').Value);
    // --- Формируем отчет по итоговому MessagesArray ---
    var DebugList := TStringList.Create;
    try
      DebugList.Add('Sending to ' + IfThen(IsOpenRouter, 'OpenRouter', 'Ollama') + ' ' + IntToStr(MessagesArray.Count) + ' messages ('+mode+' mode)');
      for I := 0 to MessagesArray.Count - 1 do begin
        var Item := TJSONObject(MessagesArray.Items[I]);
        var Role := Item.GetValue('role').Value;
        var Content := Item.GetValue('content').Value;
        var Preview := Copy(Content, 1, 30).Replace(sLineBreak, ' ').Replace(#13#10, ' ').Replace(#13, ' ').Replace(#10, ' ').Trim();
        var HasFile := '';
        var len:=Length(Content);
        if Assigned(Item.GetValue('file')) then begin
          HasFile := '+'+extractFileName(Item.GetValue('file').Value);
          len:=len+TFile.GetSize(Item.GetValue('file').Value);
        end;
        DebugList.Add(Role + ' - ' + Preview + ' ... (' + IntToStr(len) + ' chars) ' + HasFile);
      end;
      DebugList.Add('');
      TThread.Synchronize(nil, procedure begin
        SummaryMemo.Lines.AddStrings(DebugList);
        SummaryMemo.Lines.Add('');
      end);
    finally
      DebugList.Free;
    end;

    //отправим в модель!
    FCurrentRequestStart := Now;
    var RespJson := GetPost2Ollama(modelUrlEdit.Text + '/api/chat', ReqBody, 600000);
    var AnswerText := '';
    var error:='';
    if Assigned(RespJson) then begin
      if Assigned(RespJson.GetValue('error')) then begin
        if IsOpenRouter and (RespJson.GetValue('error') is TJSONObject) then begin
          // Формат OpenRouter: {"error": {"message": "...", "code": 401}}
          error := (RespJson.GetValue('error') as TJSONObject).GetValue<string>('message', '');
        end else begin
          // У Ollama ошибка — это строка {"error": "..."}
          error := RespJson.GetValue<string>('error', '');
        end;
      end;
      if error.IsEmpty then begin
        if IsOpenRouter then begin
          // Формат OpenAI: {"choices": [{"message": {"content": "..."}}]}
          var Choices := RespJson.GetValue<TJSONArray>('choices');
          if Assigned(Choices) and (Choices.Count > 0) then begin
            var MsgObj := (Choices.Items[0] as TJSONObject).GetValue<TJSONObject>('message');
            if Assigned(MsgObj) then AnswerText := MsgObj.GetValue<string>('content', '');
          end;
        end else begin
          // Формат Ollama
          AnswerText := RespJson.GetValue<string>('response', ''); //для ендпойнта /api/generate
          if AnswerText = '' then begin
            var MsgObj := RespJson.GetValue<TJSONObject>('message'); //для ендпойнта /api/chat
            if Assigned(MsgObj) then AnswerText := MsgObj.GetValue<string>('content', '');
          end;
        end;
      end;
      RespJson.Free;
    end;
    if AnswerText.IsEmpty and error.IsEmpty then error:='Failed or empty response';

    //статы времени ответа
    var Elapsed := Round(86400*(Now-FCurrentRequestStart));
    if (Elapsed>1) and (ModelComboBox.Text<>'') then begin
      var OldMax := 0;
      var S, D, C, M: string;
      if FModelStats.TryGetValue(GetModelKey(ModelComboBox.Text), S) and ParseStat(S, D, C, M) then OldMax := StrToIntDef(M, 0);
      if Elapsed>OldMax then SetStatField(GetModelKey(ModelComboBox.Text), 'maxsec', IntToStr(Elapsed));
    end;

    // Отображаем и сохраняем ответ
    TThread.Synchronize(nil,procedure begin
      StatusBar1.Panels[0].Text := 'Ready';
      if mode = 'summarize' then begin
        //суммаризация
        if error.IsEmpty then begin
          // отделим всё старое саммари
          var ExistingSummary := '';
          for var I := FHistory.Count - 1 downto 0 do begin
            if (TJSONObject(FHistory.Items[I]).GetValue('role').Value = 'system') and
              TJSONObject(FHistory.Items[I]).GetValue('content').Value.StartsWith('Context Summary: ') then begin
              ExistingSummary := TJSONObject(FHistory.Items[I]).GetValue('content').Value + sLineBreak + ExistingSummary; //в обратном порядке
              FHistory.Remove(I).free;
            end;
          end;
          AnswerText:='Context Summary: '+ExistingSummary +sLineBreak + AnswerText;
          //отделим последние диалоги как есть
          var LastDialogs := TJSONArray.Create;
          var DialogsToKeep := Min(4, FHistory.Count);
          for var I := FHistory.Count - DialogsToKeep to FHistory.Count - 1 do LastDialogs.AddElement(TJSONObject(FHistory.Items[I]).Clone as TJSONObject);
          for var I := FHistory.Count - 1 downto FHistory.Count - DialogsToKeep do FHistory.Remove(I).Free;
          //Добавим саммари
          var MsgObj := TJSONObject.Create;
          MsgObj.AddPair('role', 'system');
          MsgObj.AddPair('content', AnswerText);
          FHistory.AddElement(MsgObj);
          //вернем последние диалоги как есть
          for var I := 0 to LastDialogs.Count - 1 do
            FHistory.AddElement(TJSONObject(LastDialogs.Items[I]).Clone as TJSONObject);
          FreeAndNil(LastDialogs);
          //дебажный профит
          var ReductionPct := 0;
          if CharCountBefore > 0 then ReductionPct := Round((1 - (Length(AnswerText) / CharCountBefore)) * 100);
          SummaryMemo.Lines.Add('Summary updated. Original: ' + IntToStr(CharCountBefore) + ' chars. New: ' + IntToStr(Length(AnswerText)) + ' chars. Reduced: ' + IntToStr(ReductionPct) + '%');
          SummaryMemo.Lines.Add('Summary is: '+AnswerText);
          SummaryMemo.Lines.Add('');
        end;

      end else begin
        //обычный чат
        AnswerRichEdit.Lines.text:=AnswerRichEdit.Lines.text //используем Lines.text, а не Lines.Add чтобы были переносы строк из сырой олламы.
          +ifthen(not error.IsEmpty,'Error: '+error,'assistant: '+ sLineBreak+AnswerText) //+UTF8Decode(AnswerText)
          +sLineBreak;
        AnswerRichEdit.Lines.add(''); //чтобы вернула курсор в конец
        FormatRichEdit(AnswerRichEdit);

        if error.IsEmpty then begin
          //получен ответ
          var MsgObj := TJSONObject.Create;
          MsgObj.AddPair('role', 'assistant');
          MsgObj.AddPair('content', AnswerText);
          FHistory.AddElement(MsgObj);
          QuestionMemo.Text:='';
        end else if FHistory.Count>0 then begin
          //ответ не получен, повторить
          var Item := TJSONObject(FHistory.Items[FHistory.Count - 1]);
          if Item.GetValue('role').Value = 'user' then begin
            //dont!он испорчен аттачем, просто оставь поле ввода как есть! QuestionMemo.Text:=Item.GetValue('content').Value;
            AttachFileCheckBox.checked:=Assigned(Item.GetValue('file'));
            FHistory.Remove(FHistory.Count - 1).free;
          end;
        end;
        if QuestionMemo.CanFocus then QuestionMemo.SetFocus;
      end;
      SaveHistoryToFile;
    end);
  finally
    ReqBody.Free;
  end;
end;
procedure TChatForm.FormatRichEdit(Rich: TRichEdit);
var
  P, StartPos: Integer;
  S: string;
begin
  S := Rich.Text;

  // --- **жирный** ---
  for var i := 0 to Rich.Lines.Count - 1 do begin
    var L := Rich.Lines[i];
    var LineStart := Rich.Perform(EM_LINEINDEX, i, 0);
    P := Pos('**', L);
    while P > 0 do  begin
      var P2 := PosEx('**', L, P + 2);
      if P2 = 0 then Break;
      Rich.SelStart := LineStart + (P - 1);
      Rich.SelLength := P2 - P+2;
      Rich.SelAttributes.Style := [fsBold];
      //Rich.SelAttributes.Color := clNavy;
      P := PosEx('**', L, P2 + 2);
    end;
  end;

  // --- ### заголовки ---
  for var i := 0 to Rich.Lines.Count - 1 do begin
    var L := Rich.Lines[i];
    if L.StartsWith('### ') or L.StartsWith('#### ') then  begin
      var LineStart := Rich.Perform(EM_LINEINDEX, i, 0);
      Rich.SelStart := LineStart;
      Rich.SelLength := Length(L);
      Rich.SelAttributes.Style := [fsBold];
      Rich.SelAttributes.Size := Rich.Font.Size + 2;
    end;
  end;

  // --- * пункты ---
  for var i := 0 to Rich.Lines.Count - 1 do begin
    var L := Rich.Lines[i];
    if L.StartsWith('* ') or L.StartsWith('- ') then  begin
      var LineStart := Rich.Perform(EM_LINEINDEX, i, 0);
      Rich.SelStart := LineStart;
      Rich.SelLength := 2;
      Rich.SelAttributes.Style := [fsBold];
      Rich.SelAttributes.Color := clGreen;
      Rich.SelAttributes.Size := Rich.Font.Size + 7;
    end;
  end;

  // --- ```код``` блоки ---
  var InBlock := False;
  var BlockLineStart := 0;
  for var i := 0 to Rich.Lines.Count - 1 do begin
    var L := Rich.Lines[i];
    var LineStart := Rich.Perform(EM_LINEINDEX, i, 0);
    if L.StartsWith('```') then  begin
      if not InBlock then    begin
        InBlock := True;
        BlockLineStart := LineStart;
      end    else    begin
        Rich.SelStart := BlockLineStart;
        Rich.SelLength := (LineStart + Length(L)) - BlockLineStart;
        Rich.SelAttributes.Name := 'Consolas';
        Rich.SelAttributes.Color := clMaroon;
        //Rich.SelAttributes.BackColor := clInfoBk;
        InBlock := False;
      end;
    end;
  end;
  // незакрытый блок (модель оборвалась) — покрасим до конца
  if InBlock then begin
    Rich.SelStart := BlockLineStart;
    Rich.SelLength := Rich.GetTextLen - BlockLineStart;
    Rich.SelAttributes.Name := 'Consolas';
    Rich.SelAttributes.Color := clMaroon;
    //Rich.SelAttributes.BackColor := clInfoBk;
  end;


  // курсор в конец
  Rich.SelStart := Rich.GetTextLen;
  Rich.SelLength := 0;
end;

procedure TChatForm.btnSendClick(Sender: TObject);
begin  //Юзер задает вопрос!
  var Q := trim(QuestionMemo.Text);
  if (Q='')or(not btnSend.Enabled) then exit;
  DisableUI;
  if AttachFileCheckBox.Checked then begin
    //добавим вложение если надо
    if selectedFile='' then AnswerRichEdit.Lines.Add('Warning: selectedFile is empty');
    if not FileExists(selectedFile) then AnswerRichEdit.Lines.Add('Warning: no file '+selectedFile);
    if not AttachFileCheckBox.enabled then AnswerRichEdit.Lines.Add('Warning: attaching is disabled');
    if AttachFileCheckBox.enabled and FileExists(selectedFile) then begin
      Q := Q + sLineBreak + cAttachBoundary + ' '+extractFileName(selectedFile);
    end else
      selectedFile:='';
  end;
  //в UI
  AnswerRichEdit.Lines.Add('user: '+sLineBreak+ Q +sLineBreak);
  //во внутреннюю историю - и уйдет в модель
  var MsgObj := TJSONObject.Create;
  MsgObj.AddPair('role', 'user');
  MsgObj.AddPair('content', Q);
  if AttachFileCheckBox.Checked then MsgObj.AddPair('file', selectedFile);
  FHistory.AddElement(MsgObj);

  TThread.CreateAnonymousThread(procedure begin
    try
      TThread.Synchronize(nil, procedure begin
        AttachFileCheckBox.Checked:=false;
        StatusBar1.Panels[0].Text := 'Summarizing history...';
      end);
      SummarizeHistoryIfNeeded;
      ChatWithOllama;
    finally
      TThread.Synchronize(nil, procedure begin
        DisableUI(stReady); // Разблокируем UI
        if QuestionMemo.CanFocus then QuestionMemo.SetFocus;
      end);
    end;
  end).Start;

end;
procedure TChatForm.updateOllamaContextLimit;
var  NewLimit: Integer;
begin
  if not TryStrToInt(ModelContextLimitEdit.Text, NewLimit) or (NewLimit <= 0) then begin
    // Если в поле мусор или <= 0, ругаемся и ставим дефолт
    AnswerRichEdit.Lines.Add('Error: Invalid Context Limit. Reset to default 4096.');
    FModelContextLimit := 4096;
    ModelContextLimitEdit.Text := '4096';
  end else
    FModelContextLimit := NewLimit;
  TokenUsageProgressBar.Max := FModelContextLimit;
end;

//help   & debug
procedure TChatForm.Button1Click(Sender: TObject);
begin
  AnswerRichEdit.Lines.Text := AnswerRichEdit.Lines.Text+sLineBreak
    +'Short notes about models:'+sLineBreak
    +'How to add a model to the list? Look for the model here: https://ollama.com/search?c=cloud. Then in the console, run `ollama pull name`, for example, `ollama pull deepseek-v4-flash:cloud`. (To delete an old model, use `ollama rm name`.) Add `":cloud"` to make it cloud-based; otherwise, it will download locally!'+sLineBreak
    +'If the chat returns a 4xx error and the model is missing in the Ollama GUI (it shows “pull model manifest: file does not exist”), then go to Upcoming retirements https://docs.ollama.com/cloud and see what you can use as a replacement.'+sLineBreak
    +'It’s impossible to say in advance which cloud model will remain free with the free subscription.. But this might say https://ollama.com/settings.';
  AnswerRichEdit.Lines.Add('');//возвра курсора в конец
end;
procedure TChatForm.SummaryMemoShowButtonClick(Sender: TObject);
begin
  SummaryMemo.Visible:=not SummaryMemo.Visible;
  SummaryMemo.BringToFront;
end;



end.
