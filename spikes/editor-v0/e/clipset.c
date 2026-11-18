// Own X11 CLIPBOARD with multiple typed targets (stand-in for a file manager / browser copy). usage: clipset <case>
#include <gtk/gtk.h>
#include <stdio.h>
#include <string.h>
static char fx[1024];
static char *keys[4]; static guchar *vals[4]; static gsize lens[4]; static int n=0;
static void add(const char*k,const guchar*v,gsize l){keys[n]=strdup(k);vals[n]=g_memdup2(v,l);lens[n]=l;n++;}
static void addfile(const char*k,const char*p){gchar*d;gsize l;if(!g_file_get_contents(p,&d,&l,NULL)){fprintf(stderr,"cannot read %s\n",p);exit(2);}add(k,(guchar*)d,l);}
static void get(GtkClipboard*c,GtkSelectionData*s,guint info,gpointer u){gtk_selection_data_set(s,gtk_selection_data_get_target(s),8,vals[info],lens[info]);}
static void clr(GtkClipboard*c,gpointer u){}
int main(int argc,char**argv){gtk_init(&argc,&argv);
 if(argc<2){fprintf(stderr,"usage: clipset <case> [fixtures_dir]\n");return 2;}
 const char*c=argv[1]; const char*dir=argc>=3?argv[2]:"fixtures";
 snprintf(fx,sizeof fx,"%s/",dir);
 const char*uri_suffix="red.png"; char uri[1200]; snprintf(uri,sizeof uri,"file://%s%s",fx,uri_suffix); char buf[1400]; char path[1200];
 if(!strcmp(c,"file")||!strcmp(c,"filetext")){snprintf(buf,sizeof buf,"%s\r\n",uri);add("text/uri-list",(guchar*)buf,strlen(buf));snprintf(buf,sizeof buf,"copy\n%s",uri);add("x-special/gnome-copied-files",(guchar*)buf,strlen(buf));}
 if(!strcmp(c,"text")||!strcmp(c,"filetext")){const char*t="/some/path/not/a/file.png";add("text/plain",(guchar*)t,strlen(t));add("UTF8_STRING",(guchar*)t,strlen(t));}
 if(!strcmp(c,"png")){snprintf(path,sizeof path,"%sred.png",fx);addfile("image/png",path);}
 if(!strcmp(c,"png_html")){snprintf(path,sizeof path,"%sred.png",fx);addfile("image/png",path);const char*h="<meta charset=\"utf-8\"><img src=\"https://example.com/a.png\" alt=\"x\">";add("text/html",(guchar*)h,strlen(h));}
 if(!strcmp(c,"truncated")){snprintf(path,sizeof path,"%struncated.png",fx);addfile("image/png",path);}
 if(!strcmp(c,"random")){snprintf(path,sizeof path,"%srandom.png",fx);addfile("image/png",path);}
 if(!strcmp(c,"huge120")){snprintf(path,sizeof path,"%shuge_120mb.bin",fx);addfile("image/png",path);}
 if(!strcmp(c,"hugedims")){snprintf(path,sizeof path,"%shuge_dims.png",fx);addfile("image/png",path);}
 GtkTargetEntry t[4];for(int i=0;i<n;i++){t[i].target=keys[i];t[i].flags=0;t[i].info=i;}
 GtkClipboard*cb=gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
 gtk_clipboard_set_with_data(cb,t,n,get,clr,NULL);
 printf("clipboard set: %s (%d targets)\n",c,n);fflush(stdout);gtk_main();}
