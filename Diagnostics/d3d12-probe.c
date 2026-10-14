typedef unsigned int UINT;
typedef int HRESULT;
typedef void *HANDLE;
typedef struct { UINT a; unsigned short b,c; unsigned char d[8]; } GUID;
#define IMPORT __declspec(dllimport)
IMPORT HANDLE __stdcall LoadLibraryA(const char *);
IMPORT void *__stdcall GetProcAddress(HANDLE,const char *);
IMPORT UINT __stdcall GetLastError(void);
IMPORT HANDLE __stdcall GetStdHandle(UINT);
IMPORT int __stdcall WriteFile(HANDLE,const void *,UINT,UINT *,void *);
IMPORT UINT __stdcall GetModuleFileNameA(HANDLE,char *,UINT);
IMPORT void __stdcall ExitProcess(UINT);
static HANDLE output;
static void print(const char *s) { UINT n=0, written; while(s[n]) n++; WriteFile(output,s,n,&written,(void*)0); }
static void hex(UINT v) { char b[11]; const char *digits="0123456789abcdef"; b[0]='0';b[1]='x'; for(UINT i=0;i<8;i++) b[2+i]=digits[(v>>(28-4*i))&15];b[10]=0;print(b); }
static void field(const char *label,UINT v) { print(label);hex(v);print("\n"); }
typedef HRESULT (__stdcall *CreateDevice)(void *,UINT,const GUID *,void **);
typedef HRESULT (__stdcall *CheckFeature)(void *,UINT,void *,UINT);
typedef UINT (__stdcall *ReleaseObject)(void *);
typedef struct { UINT count; const UINT *requested; UINT maximum; } FeatureLevels;
typedef struct { UINT highest; } ShaderModel;
typedef struct { UINT waveOps,laneMin,laneMax,laneTotal,expandedCompute,int64; } Options1;
static const GUID deviceIID={0x189819f1,0x1db6,0x4b57,{0xbe,0x54,0x18,0x21,0x33,0x9b,0x85,0xf7}};
void mainCRTStartup(void) {
 output=GetStdHandle((UINT)-11);
 print("PORTICO_D3D12_CAPABILITY_PROBE_V1\n");
 HANDLE module=LoadLibraryA("d3d12.dll");
 if(!module) {field("load_error=",GetLastError());ExitProcess(2);}
 char path[1024];UINT len=GetModuleFileNameA(module,path,1023);path[len]=0;print("provider=");print(path);print("\n");
 CreateDevice create=(CreateDevice)GetProcAddress(module,"D3D12CreateDevice");
 if(!create) {field("export_error=",GetLastError());ExitProcess(3);}
 UINT levels[]={0xb000,0xb100,0xc000,0xc100,0xc200};
 for(UINT i=0;i<5;i++) {
  void *device=(void*)0;HRESULT result=create((void*)0,levels[i],&deviceIID,&device);
  print("create requested=");hex(levels[i]);print(" hr=");hex((UINT)result);print(device ? " device=yes\n":" device=no\n");
  if(result>=0 && device) {
   void **vtable=*(void***)device;CheckFeature check=(CheckFeature)vtable[13];
   FeatureLevels feature={5,levels,0};result=check(device,2,&feature,sizeof(feature));field("feature_levels_hr=",(UINT)result);field("maximum_feature_level=",feature.maximum);
   UINT models[]={0x68,0x67,0x66,0x65,0x60,0x51};
   for(UINT m=0;m<6;m++) { ShaderModel shader={models[m]};result=check(device,7,&shader,sizeof(shader));print("shader requested=");hex(models[m]);print(" hr=");hex((UINT)result);print(" maximum=");hex(shader.highest);print("\n"); if(result>=0)break; }
   UINT options[15];for(UINT o=0;o<15;o++)options[o]=0;
   result=check(device,0,options,sizeof(options));field("options_hr=",(UINT)result);field("tiled_resources_tier=",options[3]);field("resource_binding_tier=",options[4]);field("typed_uav_additional_formats=",options[6]);field("rovs=",options[7]);field("conservative_raster_tier=",options[8]);
   Options1 waves={0,0,0,0,0,0};result=check(device,8,&waves,sizeof(waves));field("options1_hr=",(UINT)result);field("wave_ops=",waves.waveOps);field("wave_lane_min=",waves.laneMin);field("wave_lane_max=",waves.laneMax);field("int64_shader_ops=",waves.int64);
   ((ReleaseObject)vtable[2])(device);
  }
 }
 print("PROBE_COMPLETE\n");ExitProcess(0);
}
