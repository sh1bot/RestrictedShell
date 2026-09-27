#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#pragma comment(lib,"advapi32.lib")

#ifndef PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY
#define PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY ((DWORD_PTR)0x0002000E)
#endif
#ifndef PROCESS_CREATION_CHILD_PROCESS_RESTRICTED
#define PROCESS_CREATION_CHILD_PROCESS_RESTRICTED 0x01
#endif

#pragma optimize("", off)
extern "C" void* memset(void* dst, int value, size_t count)
{
    unsigned char* p=(unsigned char*)dst;
    while(count--) *p++=(unsigned char)value;
    return dst;
}
#pragma optimize("", on)

extern "C" int _fltused=0;

static HHOOK hk;
static HANDLE child;
static HWND mw,ow;
static IMMDeviceEnumerator* de;
static IAudioEndpointVolume *out,*mic;
static WCHAR ot[32],ov[32];

static WCHAR argsbuf[32768];
static WCHAR preargsbuf[32768];
static WCHAR precmd[32768];
static BOOL logoffOnExit=TRUE;
static BOOL blockShellHotkeys=TRUE;
static BOOL preventChildProcesses=FALSE;
static BOOL standardKeyboardVolumeShortcuts=FALSE;
static WCHAR inipath[MAX_PATH];
static WCHAR username[256];

enum { T_PROCESS=1,T_OSD=2 };

static BOOL dn(int k){return(GetAsyncKeyState(k)&0x8000)!=0;}

static void cp(WCHAR*d,const WCHAR*s,int n)
{
    if(!n)return;
    while(--n&&(*d++=*s++));
    *d=0;
}

static BOOL ap(WCHAR*d,int n,const WCHAR*s)
{
    int i=0;
    while(i<n&&d[i])i++;
    if(i>=n)return FALSE;
    while(*s){
        if(i+1>=n)return FALSE;
        d[i++]=*s++;
    }
    d[i]=0;
    return TRUE;
}

static WCHAR lc(WCHAR c)
{
    return(c>=L'A'&&c<=L'Z')?(WCHAR)(c+(L'a'-L'A')):c;
}

static BOOL endsi(const WCHAR*s,const WCHAR*t)
{
    int a=0,b=0;
    while(s[a])a++;
    while(t[b])b++;
    if(b>a)return FALSE;
    for(int i=0;i<b;i++)
        if(lc(s[a-b+i])!=lc(t[i]))return FALSE;
    return TRUE;
}

static void workdir(const WCHAR*e,WCHAR*wd)
{
    cp(wd,e,MAX_PATH);
    WCHAR*x=0;
    for(WCHAR*q=wd;*q;q++)
        if(*q==L'\\'||*q==L'/')x=q;
    if(x)*x=0;else wd[0]=0;
}

static void show(const WCHAR*t,const WCHAR*v)
{
    cp(ot,t,32); cp(ov,v,32);
    RECT r;
    SystemParametersInfoW(SPI_GETWORKAREA,0,&r,0);
    SetWindowPos(ow,HWND_TOPMOST,
        r.left+(r.right-r.left-360)/2,
        r.top+(r.bottom-r.top-104)/2,
        360,104,SWP_NOACTIVATE|SWP_SHOWWINDOW);
    InvalidateRect(ow,0,TRUE);
    UpdateWindow(ow);
    KillTimer(ow,T_OSD);
    SetTimer(ow,T_OSD,1200,0);
}

static void pct(int v,WCHAR*b)
{
    WCHAR q[8],r[8];
    int i=0,j=0;
    if(!v)q[j++]=L'0';
    else {
        while(v){r[i++]=(WCHAR)(L'0'+v%10);v/=10;}
        while(i)q[j++]=r[--i];
    }
    q[j++]=L'%';q[j]=0;cp(b,q,32);
}

static void showvol()
{
    if(!out){show(L"Volume",L"ERROR");return;}
    BOOL m=FALSE;float f=0;
    if(FAILED(out->GetMute(&m))||
       FAILED(out->GetMasterVolumeLevelScalar(&f))){
        show(L"Volume",L"ERROR");return;
    }
    if(m)show(L"Volume",L"MUTED");
    else {
        WCHAR b[32];
        pct((int)(f*100.0f+0.5f),b);
        show(L"Volume",b);
    }
}

static void volume(float d)
{
    if(out){
        float f;
        if(SUCCEEDED(out->GetMasterVolumeLevelScalar(&f))){
            f+=d;
            if(f<0)f=0;
            if(f>1)f=1;
            out->SetMasterVolumeLevelScalar(f,0);
        }
    }
    showvol();
}

static void outmute()
{
    if(out){
        BOOL m;
        if(SUCCEEDED(out->GetMute(&m)))out->SetMute(!m,0);
    }
    showvol();
}

static void micmute()
{
    if(!mic){show(L"Microphone",L"ERROR");return;}
    BOOL m=FALSE;
    if(FAILED(mic->GetMute(&m))){
        show(L"Microphone",L"ERROR");return;
    }
    mic->SetMute(!m,0);
    m=FALSE;
    show(L"Microphone",
        SUCCEEDED(mic->GetMute(&m))?(m?L"MUTED":L"ON"):L"ERROR");
}

static void audioinit()
{
    if(FAILED(CoCreateInstance(
        __uuidof(MMDeviceEnumerator),0,CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&de))))return;

    IMMDevice*d=0;
    if(SUCCEEDED(de->GetDefaultAudioEndpoint(eRender,eMultimedia,&d))){
        d->Activate(__uuidof(IAudioEndpointVolume),
            CLSCTX_INPROC_SERVER,0,(void**)&out);
        d->Release();
    }

    d=0;
    if(SUCCEEDED(de->GetDefaultAudioEndpoint(eCapture,eCommunications,&d))){
        d->Activate(__uuidof(IAudioEndpointVolume),
            CLSCTX_INPROC_SERVER,0,(void**)&mic);
        d->Release();
    }
}

static BOOL blockedwin(DWORD v)
{
    switch(v){
    case'R':case'E':case'I':case'S':case VK_TAB:case'D':
    case'X':case'A':case'N':case'P':case'K':
        return TRUE;
    }
    return FALSE;
}

static LRESULT CALLBACK keyproc(int n,WPARAM w,LPARAM l)
{
    if(n<0)return CallNextHookEx(hk,n,w,l);

    KBDLLHOOKSTRUCT*k=(KBDLLHOOKSTRUCT*)l;
    BOOL d=w==WM_KEYDOWN||w==WM_SYSKEYDOWN;
    BOOL u=w==WM_KEYUP||w==WM_SYSKEYUP;
    if(!d&&!u)return CallNextHookEx(hk,n,w,l);

    DWORD v=k->vkCode;
    BOOL win=dn(VK_LWIN)||dn(VK_RWIN)||v==VK_LWIN||v==VK_RWIN;
    BOOL alt=dn(VK_LMENU)||dn(VK_RMENU);
    BOOL ctl=dn(VK_LCONTROL)||dn(VK_RCONTROL);
    BOOL sh=dn(VK_LSHIFT)||dn(VK_RSHIFT);

    if(d){
        if(v==VK_VOLUME_UP){volume(.05f);return 1;}
        if(v==VK_VOLUME_DOWN){volume(-.05f);return 1;}
        if(v==VK_VOLUME_MUTE){outmute();return 1;}

        if(standardKeyboardVolumeShortcuts&&win&&alt){
            if(v==VK_OEM_PLUS){volume(.05f);return 1;}
            if(v==VK_OEM_MINUS){volume(-.05f);return 1;}
            if(v=='M'){outmute();return 1;}
        }

        if(win&&alt&&v=='K'){micmute();return 1;}
        if(win&&v=='L'){LockWorkStation();return 1;}

        if(blockShellHotkeys){
            if(win&&blockedwin(v))return 1;
            if(alt&&(v==VK_TAB||v==VK_ESCAPE))return 1;
            if(ctl&&sh&&v==VK_ESCAPE)return 1;
            if(ctl&&v==VK_ESCAPE)return 1;
        }
    }

    if(blockShellHotkeys&&(v==VK_LWIN||v==VK_RWIN))return 1;
    return CallNextHookEx(hk,n,w,l);
}

static LRESULT CALLBACK osdproc(HWND h,UINT m,WPARAM w,LPARAM l)
{
    if(m==WM_TIMER&&w==T_OSD){
        KillTimer(h,T_OSD);
        ShowWindow(h,SW_HIDE);
        return 0;
    }

    if(m==WM_ERASEBKGND){
        RECT r;
        GetClientRect(h,&r);
        HBRUSH b=CreateSolidBrush(RGB(24,24,24));
        FillRect((HDC)w,&r,b);
        DeleteObject(b);
        return 1;
    }

    if(m==WM_PAINT){
        PAINTSTRUCT p;
        HDC d=BeginPaint(h,&p);
        RECT r;
        GetClientRect(h,&r);
        SetBkMode(d,TRANSPARENT);
        SetTextColor(d,RGB(255,255,255));

        HFONT a=CreateFontW(-21,0,0,0,FW_NORMAL,0,0,0,
            DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
        HFONT b=CreateFontW(-29,0,0,0,FW_BOLD,0,0,0,
            DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");

        HGDIOBJ old=SelectObject(d,a);
        RECT q=r;q.bottom=44;
        DrawTextW(d,ot,-1,&q,DT_CENTER|DT_VCENTER|DT_SINGLELINE);

        SelectObject(d,b);
        q=r;q.top=38;
        DrawTextW(d,ov,-1,&q,DT_CENTER|DT_VCENTER|DT_SINGLELINE);

        SelectObject(d,old);
        DeleteObject(a);
        DeleteObject(b);
        EndPaint(h,&p);
        return 0;
    }

    return DefWindowProcW(h,m,w,l);
}

static LRESULT CALLBACK msgproc(HWND h,UINT m,WPARAM w,LPARAM l)
{
    if(m==WM_TIMER&&w==T_PROCESS&&child&&
       WaitForSingleObject(child,0)==WAIT_OBJECT_0){
        KillTimer(h,T_PROCESS);
        if(logoffOnExit){
            if(!ExitWindowsEx(EWX_LOGOFF,0)){
                MessageBoxW(0,L"Target exited, but logoff failed.",
                    L"Restricted Shell",MB_ICONERROR);
                PostQuitMessage(1);
            }
        } else {
            PostQuitMessage(0);
        }
        return 0;
    }
    return DefWindowProcW(h,m,w,l);
}

static void makeinipath()
{
    DWORD n=GetModuleFileNameW(0,inipath,MAX_PATH);
    if(!n||n>=MAX_PATH){inipath[0]=0;return;}
    WCHAR*slash=0;
    for(WCHAR*p=inipath;*p;p++)
        if(*p==L'\\'||*p==L'/')slash=p;
    if(slash)cp(slash+1,L"RestrictedShell.ini",
        MAX_PATH-(int)(slash+1-inipath));
    else cp(inipath,L"RestrictedShell.ini",MAX_PATH);
}

static void getconfig(const WCHAR*key,const WCHAR*fallback,
    WCHAR*outbuf,DWORD outchars)
{
    static WCHAR base[32768];

    base[0]=0;
    GetPrivateProfileStringW(
        L"RestrictedShell",key,fallback,
        base,32768,inipath);

    if(username[0])
        GetPrivateProfileStringW(
            username,key,base,
            outbuf,outchars,inipath);
    else
        cp(outbuf,base,(int)outchars);
}

static BOOL startproc(const WCHAR*app,WCHAR*cmd,const WCHAR*wd,
    BOOL restrictChildren,HANDLE*outProcess)
{
    PROCESS_INFORMATION p;
    memset(&p,0,sizeof(p));

    BOOL ok=FALSE;
    if(!restrictChildren){
        STARTUPINFOW s;
        memset(&s,0,sizeof(s));
        s.cb=sizeof(s);
        ok=CreateProcessW(app,cmd&&cmd[0]?cmd:0,0,0,FALSE,0,0,
            wd&&wd[0]?wd:0,&s,&p);
    } else {
        SIZE_T bytes=0;
        InitializeProcThreadAttributeList(0,1,0,&bytes);
        if(!bytes)return FALSE;

        LPPROC_THREAD_ATTRIBUTE_LIST attrs=
            (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
                GetProcessHeap(),0,bytes);
        if(!attrs)return FALSE;

        STARTUPINFOEXW sx;
        memset(&sx,0,sizeof(sx));
        sx.StartupInfo.cb=sizeof(sx);
        sx.lpAttributeList=attrs;

        if(InitializeProcThreadAttributeList(attrs,1,0,&bytes)){
            DWORD policy=PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;
            if(UpdateProcThreadAttribute(
                attrs,0,PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY,
                &policy,sizeof(policy),0,0)){
                ok=CreateProcessW(
                    app,cmd&&cmd[0]?cmd:0,0,0,FALSE,
                    EXTENDED_STARTUPINFO_PRESENT,0,
                    wd&&wd[0]?wd:0,&sx.StartupInfo,&p);
            }
            DeleteProcThreadAttributeList(attrs);
        }
        HeapFree(GetProcessHeap(),0,attrs);
    }

    if(!ok)return FALSE;
    CloseHandle(p.hThread);
    *outProcess=p.hProcess;
    return TRUE;
}

static BOOL prerun()
{
    WCHAR pre[MAX_PATH];
    pre[0]=0;
    getconfig(L"PreRunExecutable",L"",pre,MAX_PATH);
    if(!pre[0])return TRUE;

    preargsbuf[0]=0;
    getconfig(L"PreRunArguments",L"",preargsbuf,32768);

    WCHAR app[MAX_PATH];
    WCHAR wd[MAX_PATH];
    workdir(pre,wd);
    cp(app,pre,MAX_PATH);
    WCHAR*cmd=preargsbuf;

    if(endsi(pre,L".bat")||endsi(pre,L".cmd")){
        DWORD n=GetEnvironmentVariableW(L"ComSpec",app,MAX_PATH);
        if(!n||n>=MAX_PATH)return FALSE;
        precmd[0]=0;
        if(!ap(precmd,32768,L"/d /s /c \"\"")||
           !ap(precmd,32768,pre)||
           !ap(precmd,32768,L"\"")||
           (preargsbuf[0]&&(!ap(precmd,32768,L" ")||
                            !ap(precmd,32768,preargsbuf)))||
           !ap(precmd,32768,L"\""))return FALSE;
        cmd=precmd;
    } else if(endsi(pre,L".ps1")){
        DWORD n=GetWindowsDirectoryW(app,MAX_PATH);
        if(!n||n>=MAX_PATH)return FALSE;
        if(!ap(app,MAX_PATH,L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"))
            return FALSE;
        precmd[0]=0;
        if(!ap(precmd,32768,L"-NoProfile -ExecutionPolicy Bypass -File \"")||
           !ap(precmd,32768,pre)||
           !ap(precmd,32768,L"\"")||
           (preargsbuf[0]&&(!ap(precmd,32768,L" ")||
                            !ap(precmd,32768,preargsbuf))))return FALSE;
        cmd=precmd;
    }

    HANDLE p=0;
    if(!startproc(app,cmd,wd,FALSE,&p))return FALSE;
    WaitForSingleObject(p,INFINITE);
    CloseHandle(p);
    return TRUE;
}

static BOOL launch(const WCHAR*e)
{
    argsbuf[0]=0;
    getconfig(L"Arguments",L"",argsbuf,32768);

    WCHAR wd[MAX_PATH];
    workdir(e,wd);
    return startproc(e,argsbuf,wd,preventChildProcesses,&child);
}

extern "C" void WINAPI entry()
{
    HINSTANCE i=GetModuleHandleW(0);
    CoInitializeEx(0,COINIT_APARTMENTTHREADED);

    makeinipath();

    username[0]=0;
    DWORD userchars=(DWORD)(sizeof(username)/sizeof(username[0]));
    if(!GetUserNameW(username,&userchars))
        username[0]=0;

    WCHAR logoffValue[16];
    getconfig(L"LogoffOnExit",L"1",logoffValue,16);
    logoffOnExit = !(logoffValue[0]==L'0' && logoffValue[1]==0);

    WCHAR blockValue[16];
    getconfig(L"BlockShellHotkeys",L"1",blockValue,16);
    blockShellHotkeys = !(blockValue[0]==L'0' && blockValue[1]==0);

    WCHAR childValue[16];
    getconfig(L"PreventChildProcesses",L"0",childValue,16);
    preventChildProcesses = !(childValue[0]==L'0' && childValue[1]==0);

    WCHAR volumeShortcutValue[16];
    getconfig(L"StandardKeyboardVolumeShortcuts",L"0",volumeShortcutValue,16);
    standardKeyboardVolumeShortcuts =
        !(volumeShortcutValue[0]==L'0' && volumeShortcutValue[1]==0);

    WNDCLASSW a,b;
    memset(&a,0,sizeof(a));
    memset(&b,0,sizeof(b));

    a.lpfnWndProc=msgproc;
    a.hInstance=i;
    a.lpszClassName=L"RSM";
    RegisterClassW(&a);

    b.lpfnWndProc=osdproc;
    b.hInstance=i;
    b.lpszClassName=L"RSO";
    RegisterClassW(&b);

    mw=CreateWindowExW(0,L"RSM",L"",0,0,0,0,0,
        HWND_MESSAGE,0,i,0);
    ow=CreateWindowExW(
        WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,
        L"RSO",L"",WS_POPUP,0,0,360,104,0,0,i,0);

    audioinit();

    hk=SetWindowsHookExW(WH_KEYBOARD_LL,keyproc,i,0);
    if(!hk){
        MessageBoxW(0,L"Could not install keyboard hook.",
            L"Restricted Shell",MB_ICONERROR);
        ExitProcess(3);
    }

    if(!prerun()){
        MessageBoxW(0,L"Could not launch the configured pre-run program.",
            L"Restricted Shell",MB_ICONERROR);
        ExitProcess(4);
    }

    WCHAR exe[MAX_PATH];
    exe[0]=0;
    getconfig(L"Executable",L"",exe,MAX_PATH);

    if(!exe[0]||!launch(exe)){
        MessageBoxW(0,
            L"Could not launch Executable in RestrictedShell.ini.",
            L"Restricted Shell",MB_ICONERROR);
        ExitProcess(2);
    }

    SetTimer(mw,T_PROCESS,500,0);

    MSG m;
    while(GetMessageW(&m,0,0,0)>0){
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }

    ExitProcess((UINT)m.wParam);
}
