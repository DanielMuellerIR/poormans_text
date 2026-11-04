#include <poppler.h>
#include <stdio.h>
int main(int argc, char **argv) { if(argc!=2)return 64; GError *e=NULL; char *uri=g_filename_to_uri(argv[1],NULL,&e); if(!uri)return 65; PopplerDocument *d=poppler_document_new_from_file(uri,NULL,&e); g_free(uri); if(!d)return 1; PopplerPage *p=poppler_document_get_page(d,0); GList *links=poppler_page_get_link_mapping(p); for(GList *l=links;l;l=l->next){PopplerLinkMapping *m=l->data;if(m->action && m->action->type==POPPLER_ACTION_URI)puts(m->action->uri.uri);}poppler_page_free_link_mapping(links);g_object_unref(p);g_object_unref(d);}
