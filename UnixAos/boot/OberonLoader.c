/* 
   G.F. 31.01.2017

   Loader for statically linked oberon binaries.

   Compile command:
      gcc -m32 -s -O OberonLoader.c -ldl -o OberonLoader

      gcc -m64 -s -O OberonLoader.c -ldl -o OberonLoader


   The statically linked oberon binary 'oberon.bin' has to be
   appended to this loader by the following A2-command:

      UnixBinary.Build oberon.bin ->  <program name> ~

*/
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>
#include <dlfcn.h>
#include <signal.h>
#if defined(__APPLE__) && defined(__aarch64__)
#include <libkern/OSCacheControl.h>
#endif

#define Offset 16*1024	/* startpos of the appended oberon binary */
#define BlkSize 4*1024

typedef void (*OberonProc)();
typedef void *addr;
typedef unsigned int uint;
typedef unsigned long ulong;

typedef struct {  /* cf. Unix.*.Glue.Mod */
    /* Oberon --> loader: */
    char id[16];		/* must match coreID; followed by a zero version word */
    int  version;
    int  executableSize;	/* page-aligned code prefix */
    int  codesize;	
    int  relocations;
    OberonProc entry;		/* Glue.Init0 */
    /* loader --> Oberon: */
    addr *dlopenaddr;
    addr *dlcloseaddr;
    addr *dlsymaddr;
    int  *argc;
    addr *argv;
    addr *env;
    addr *cout;
} *Header;

#if defined(__LP64__) || defined(_LP64)
   char *coreID = "Oberon64G.binary";	/* cf. Unix.Glue.Mod */
#else
   char *coreID = "Oberon32G.binary";	/* cf. Unix.Glue.Mod */
#endif

addr heap;
uint heapsize;
int fd;

static void *oberon_dlopen(const char *path, int mode) {
#if defined(__linux__) && defined(__aarch64__)
   const char *name = strrchr(path, '/');
   name = name != NULL ? name + 1 : path;
   if ((strcmp(name, "libc.dylib") == 0) ||
       (strcmp(name, "libpthread.dylib") == 0))
      return dlopen("libc.so.6", mode);
   if (strcmp(name, "libX11.dylib") == 0)
      return dlopen("libX11.so.6", mode);
#endif
   return dlopen(path, mode);
}

#if defined(__aarch64__)
static void crash_report(int sig, siginfo_t *info, void *context) {
   ucontext_t *uc = (ucontext_t *)context;
#if defined(__APPLE__)
   fprintf(stderr, "signal %d at %p; core=%p pc=%p sp=%p fp=%p lr=%p x19=%p x20=%p x21=%p x22=%p\n",
           sig, info->si_addr, heap,
           (void *)uc->uc_mcontext->__ss.__pc,
           (void *)uc->uc_mcontext->__ss.__sp,
           (void *)uc->uc_mcontext->__ss.__fp,
           (void *)uc->uc_mcontext->__ss.__lr,
           (void *)uc->uc_mcontext->__ss.__x[19],
           (void *)uc->uc_mcontext->__ss.__x[20],
           (void *)uc->uc_mcontext->__ss.__x[21],
           (void *)uc->uc_mcontext->__ss.__x[22]);
#else
   fprintf(stderr, "signal %d at %p; core=%p pc=%p sp=%p fp=%p lr=%p x19=%p x20=%p x21=%p\n",
           sig, info->si_addr, heap,
           (void *)uc->uc_mcontext.pc,
           (void *)uc->uc_mcontext.sp,
           (void *)uc->uc_mcontext.regs[29],
           (void *)uc->uc_mcontext.regs[30],
           (void *)uc->uc_mcontext.regs[19],
           (void *)uc->uc_mcontext.regs[20],
           (void *)uc->uc_mcontext.regs[21]);
#endif
   _exit(128 + sig);
}

static void install_crash_reporter(void) {
   struct sigaction action;
   memset(&action, 0, sizeof(action));
   action.sa_sigaction = crash_report;
   action.sa_flags = SA_SIGINFO;
   sigaction(SIGILL, &action, NULL);
   sigaction(SIGTRAP, &action, NULL);
   sigaction(SIGBUS, &action, NULL);
   sigaction(SIGSEGV, &action, NULL);
}
#endif

void cout( char c ) {
   char buf[8];
   buf[0] = c;
   write( 1, &buf, 1 );
}

uint ReadInteger( ) {
   union {
      char buf[4];
      uint i;
   } u;
   read( fd, &u.buf, 4 );
   return (u.i);
}


void Relocate( uint relocations ) {
   addr *a;
   uint i;

   for (i=0; i<relocations; i++) {
      a = heap + ReadInteger();
      *a += (ulong)heap;
   }
}


char *which_path(const char *name) {

   char *tname, *tok, *path;

   path = strdup(getenv("PATH"));
   if (NULL == path) return NULL;

   tok = strtok(path, ":");
   while (tok) {
      tname = malloc(strlen(tok) + 2 + strlen(name));
      sprintf(tname, "%s/%s", tok, name);

      if (0 == access(tname, X_OK)) { free(path);  return tname; }

      free(tname);
      tok = strtok(NULL, ":");
   }
   free(path);
   return NULL;
}



int main( int argc, char *argv[], char *env[] ) {
   int n, binsize, relocations;
   off_t coreOffset;
   struct stat sb;
   Header header;
   char *path, *buf, *corePath;

   corePath = getenv("OBERON_CORE");
   if ((corePath != NULL) && (corePath[0] != 0)) {
      fd = open(corePath, O_RDONLY);
      coreOffset = 0;
   } else {
      fd = open( *argv, O_RDONLY );
      coreOffset = Offset;
      if (fd < 0) {
         /* find myself in PATH */
         path = which_path(*argv);
         fd = open(path, O_RDONLY);
      }
   }
   if (fd < 0) { perror("open Oberon core"); exit(2); }
   fstat( fd, &sb );
   if ( sb.st_size < coreOffset+2048 ) {
      fprintf( stderr, "%s: missing Oberon binary\n", corePath != NULL ? corePath : *argv );
      exit( 2 );
   }
   lseek( fd, coreOffset, SEEK_SET );
   buf = malloc( 512 );
   n = read( fd, buf, 256 );
   header = (Header)buf;
   if (strcmp(header->id, coreID) != 0) {
      fprintf( stderr, "wrong Oberon headerId: got '%s', expected '%s'\n", header->id, coreID );
      exit( 2 );
   }
   binsize = header->codesize;
   relocations = header->relocations;
   free( buf );

   heapsize = BlkSize;
   while (heapsize < (uint)binsize) heapsize += BlkSize;

   lseek( fd, coreOffset, SEEK_SET );
#if defined(__APPLE__) && defined(__aarch64__)
   heap = mmap(NULL, heapsize, PROT_READ|PROT_WRITE,
               MAP_PRIVATE|MAP_ANON, -1, 0);
   if (heap == MAP_FAILED) { perror("mmap Oberon core"); exit(2); }
#else
   posix_memalign( &heap, BlkSize, heapsize );
#endif
   n = read( fd, heap, binsize );
   if (n != binsize) { perror("read Oberon core"); exit(2); }

   Relocate( relocations );

   header = (Header)heap;
   *(header->dlopenaddr) = oberon_dlopen;
   *(header->dlcloseaddr) = dlclose;
   *(header->dlsymaddr) = dlsym;
   *(header->argc) = argc;
   *(header->argv) = argv;
   *(header->env)  = env;
   *(header->cout) = cout;

#if defined(__APPLE__) && defined(__aarch64__)
   if ((header->executableSize <= 0) ||
       (header->executableSize > binsize) ||
       ((header->executableSize % (16*1024)) != 0)) {
      fprintf(stderr, "invalid executable prefix size %d\n", header->executableSize);
      exit(2);
   }
   sys_icache_invalidate(heap, header->executableSize);
   if (mprotect(heap, header->executableSize, PROT_READ|PROT_EXEC) != 0) {
      perror("mprotect Oberon code");
      exit(2);
   }
#else
   if (mprotect( heap, heapsize, PROT_READ|PROT_WRITE|PROT_EXEC) != 0) {
      perror("mprotect");
      exit(2);
   }
#endif
#if defined(__aarch64__)
   install_crash_reporter();
#endif
   header->entry();
   return (0);
}
