/* Portico CEF launcher: the original Valve binary remains unchanged.
 * --single-process avoids the black CEF window on macOS Wine 11.
 * This does not change the game's rendering backend or Steam authentication.
 */
typedef unsigned short W;
typedef unsigned long D;
typedef void *H;
typedef struct { D cb; W *reserved,*desktop,*title; D x,y,xs,ys,xc,yc,fill,flags; unsigned short show,cb2; unsigned char *reserved2; H in,out,err; } SI;
typedef struct { H process,thread; D pid,tid; } PI;
__declspec(dllimport) D GetModuleFileNameW(H,W*,D);
__declspec(dllimport) W *GetCommandLineW(void);
__declspec(dllimport) int CreateProcessW(W*,W*,void*,void*,int,D,void*,W*,SI*,PI*);
__declspec(dllimport) D WaitForSingleObject(H,D);
__declspec(dllimport) int GetExitCodeProcess(H,D*);
__declspec(dllimport) int CloseHandle(H);
__declspec(dllimport) void ExitProcess(D);
static W path[32768],cmd[32768];
static SI si; static PI pi;
static unsigned n;
static void append(const W *s) { while(*s) { if(n>=32766) ExitProcess(87); cmd[n++]=*s++; } cmd[n]=0; }
void mainCRTStartup(void) {
 D len=GetModuleFileNameW(0,path,32768); if(!len||len>=32768) ExitProcess(87);
 while(len&&path[len-1]!='\\')len--; if(!len)ExitProcess(87);
 const W *name=L"steamwebhelper_original.exe"; unsigned i=0; while(name[i]) {if(len+i>=32767)ExitProcess(87);path[len+i]=name[i];i++;} path[len+i]=0;
 W *tail=GetCommandLineW(); int quote=0; while(*tail) { if(*tail=='"')quote=!quote; else if(*tail==' '&&!quote)break; tail++; }
 append(L"\"");append(path);append(L"\" --disable-gpu --single-process ");append(tail);
 si.cb=sizeof(si);
 if(!CreateProcessW(path,cmd,0,0,1,0,0,0,&si,&pi))ExitProcess(1);
 WaitForSingleObject(pi.process,0xffffffff); D code=1;GetExitCodeProcess(pi.process,&code);CloseHandle(pi.thread);CloseHandle(pi.process);ExitProcess(code);
}
