unit uMiniChatExpert;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, Vcl.Forms, Vcl.Menus,
  ToolsAPI, ToolsAPI.Editor,Vcl.Dialogs, uChatFrm,Vcl.Controls;

type
  TMiniChatExpert = class(TNotifierObject, IOTAWizard, IOTAMenuWizard)
  private
    FAIToolsSubMenu: TMenuItem;
    FMenuItem1: TMenuItem;
    FMenuItem2: TMenuItem;
    procedure OnMenuClick(Sender: TObject);
    procedure AddToToolsMenu;
    function GetSelectedText(obligatory: Boolean = False): string;
  public
    constructor Create;
    destructor Destroy; override;
    // IOTAWizard - заглушка, не работает
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
    procedure Execute;
    function GetMenuText: string;
    procedure GetEditorSelection(out selectedText, Filename: string);
  end;

procedure Register;

var
  MiniChatExpert: TMiniChatExpert;
  ExpertIndex: Integer = -1;

implementation

procedure Register;
begin
  var WizardServices := BorlandIDEServices as IOTAWizardServices;
  if Assigned(WizardServices) then ExpertIndex := WizardServices.AddWizard(TMiniChatExpert.Create);
end;

constructor TMiniChatExpert.Create;
begin
  inherited Create;
  AddToToolsMenu;
end;

procedure TMiniChatExpert.AddToToolsMenu;
begin
  // Запускаем в отдельном потоке чтобы не блокировать загрузку IDE
  TThread.CreateAnonymousThread(procedure begin
    // Ждем полной загрузки IDE
    Sleep(5000);
    TThread.Synchronize(nil,procedure begin
      var NTAServices := BorlandIDEServices as INTAServices;
      if not Assigned(NTAServices) then Exit;
      for var I := 0 to NTAServices.MainMenu.Items.Count - 1 do
        if SameText(NTAServices.MainMenu.Items[I].Name, 'ToolsMenu') then begin
          //создаем Tools - меню
          FAIToolsSubMenu := TMenuItem.Create(nil);
          FAIToolsSubMenu.Caption := 'DjChat - Simple AI Context Vibecoding Expert';//+datetimetostr(now);
          FAIToolsSubMenu.Name := 'AIToolsSubMenu';
          NTAServices.MainMenu.Items[I].Add(FAIToolsSubMenu);
          //субменю
          FMenuItem1 := TMenuItem.Create(nil);
          FMenuItem1.Caption := 'Chat';
          FMenuItem1.OnClick := OnMenuClick;
          FAIToolsSubMenu.Add(FMenuItem1);
          FMenuItem2 := TMenuItem.Create(nil);
          FMenuItem2.Caption := 'Find unit';
          FMenuItem2.tag:=2;
          FMenuItem2.OnClick := OnMenuClick;
          FAIToolsSubMenu.Add(FMenuItem2);
          Break;
        end;
      end);
    end).Start;
end;

destructor TMiniChatExpert.Destroy;
begin
  FreeAndNil(FAIToolsSubMenu);
  inherited;
end;

//необходимые заглушки - должно быть в Menu - View, но не появляется!
procedure TMiniChatExpert.Execute;
begin
  if not Assigned(Self) then Exit; // Защита от вызова после Free       //
  OnMenuClick(nil);
end;

function TMiniChatExpert.GetIDString: string;
begin
  Result := 'DjChat.Expert';
end;

function TMiniChatExpert.GetMenuText: string;
begin
  Result := 'DjChat - Simple AI Context Vibecoding Expert';
end;

function TMiniChatExpert.GetName: string;
begin
  Result := 'DjChat Expert';
end;

function TMiniChatExpert.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;




/////////////////////////////// функции сбора данных  из IDE

function TMiniChatExpert.GetSelectedText(obligatory: Boolean = False): string;
var
  EditorServices: IOTAEditorServices;
  EditView: IOTAEditView;
  EditPosition: IOTAEditPosition;
  OldRow, OldCol: Integer;
  StartChar: Char;
  LeftPart: string;
begin
    Result := '';
    EditorServices := BorlandIDEServices as IOTAEditorServices;
    if not Assigned(EditorServices) then Exit;
    EditView := EditorServices.TopView;
    if not Assigned(EditView) then Exit;
    if Assigned(EditView.Block) and (EditView.Block.Size > 0) then exit(EditView.Block.Text);
    if not obligatory then Exit;
    // таки очень надо? Получаем слово под курсором
    if not Assigned(EditView.Buffer) then Exit;
    EditPosition := EditView.Buffer.EditPosition;
    if not Assigned(EditPosition) then Exit;
    OldRow := EditPosition.Row;
    OldCol := EditPosition.Column;
    StartChar := EditPosition.Character;
    Result := StartChar; //собираем слово
    if EditPosition.MoveRelative(0, 1) then
      while EditPosition.IsWordCharacter do begin
        Result := Result + EditPosition.Character;
        if not EditPosition.MoveRelative(0, 1) then Break;
      end;
    EditPosition.Move(OldRow, OldCol);
    if EditPosition.MoveRelative(0, -1) then begin
      LeftPart := '';
      while EditPosition.IsWordCharacter do begin
        LeftPart := EditPosition.Character + LeftPart; // Добавляем в начало строки
        if not EditPosition.MoveRelative(0, -1) then Break;
      end;
    end;
    Result := trim(LeftPart + Result);
end;

function GetCurrentSourceFile: string;
var
  ModuleServices: IOTAModuleServices;
  Module: IOTAModule;
  Editor: IOTAEditor;
  I: Integer;
begin
  Result := '';
  try
    ModuleServices := BorlandIDEServices as IOTAModuleServices;
    if not Assigned(ModuleServices) then Exit;

    // Получаем текущий модуль
    Module := ModuleServices.CurrentModule;
    if not Assigned(Module) then Exit;

    // Получаем редактор исходного кода
    for I := 0 to Module.ModuleFileCount - 1 do
    begin
      Editor := Module.ModuleFileEditors[I];
      if Assigned(Editor) then
      begin
        Result := Editor.FileName;
        Exit;
      end;
    end;

  except
    Result := '';
  end;
end;

//интерактивные
procedure TMiniChatExpert.OnMenuClick(Sender: TObject);
begin
  //вызов по меню в IDE
  var selectedText:=GetSelectedText(TComponent(Sender).Tag=2);
  if (TComponent(Sender).Tag=2) and(selectedText='') then begin
    showmessage('Point a word to ask for its Unit');
    exit;
  end;
  ShowChatForm(selectedText, GetCurrentSourceFile,TComponent(Sender).Tag);
end;

procedure TMiniChatExpert.GetEditorSelection(out selectedText, Filename: string);
begin
  //обратный возов из чата при переактивации формы ввода
  selectedText:=GetSelectedText;
  Filename:=GetCurrentSourceFile;          //
end;




initialization

finalization
  if (ExpertIndex <> -1) and Assigned(BorlandIDEServices) then begin
    try
      (BorlandIDEServices as IOTAWizardServices).RemoveWizard(ExpertIndex);
    except
    end;
  end;

end.
