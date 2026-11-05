#include <libheif/heif.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void check(struct heif_error e) {if(e.code){fprintf(stderr,"%s\n",e.message);exit(1);}}
int main(int argc,char**argv){
 if(argc!=4)return 2;
 check(heif_init(NULL));
 struct heif_context*c=heif_context_alloc();struct heif_encoder*e=NULL;
 check(heif_context_get_encoder_for_format(c,heif_compression_HEVC,&e));
 check(heif_encoder_set_lossless(e,1));
 check(heif_encoder_set_parameter_string(e,"chroma","444"));
 (void)heif_encoder_set_parameter_string(e,"x265:pools","none");
 (void)heif_encoder_set_parameter_string(e,"x265:frame-threads","1");
 int count=atoi(argv[2]), orientation=atoi(argv[3]);
 for(int n=0;n<count;n++){
  int w=32+(n%2)*8,h=24;struct heif_image*i=NULL;
  check(heif_image_create(w,h,heif_colorspace_RGB,heif_chroma_interleaved_RGBA,&i));
  check(heif_image_add_plane(i,heif_channel_interleaved,w,h,8));
  int stride;unsigned char*p=heif_image_get_plane(i,heif_channel_interleaved,&stride);
  memset(p,0,(size_t)stride*h);
  for(int y=0;y<h;y++)for(int x=0;x<w;x++){
   unsigned char*q=p+y*stride+x*4;q[0]=x*7;q[1]=y*9;q[2]=n*70;q[3]=(x<8?0:255);
  }
  struct heif_encoding_options*options=heif_encoding_options_alloc();
  options->image_orientation=(enum heif_orientation)orientation;
  check(heif_context_encode_image(c,i,e,options,NULL));
  heif_encoding_options_free(options);heif_image_release(i);
 }
 check(heif_context_write_to_file(c,argv[1]));
 heif_encoder_release(e);heif_context_free(c);heif_deinit();return 0;
}
