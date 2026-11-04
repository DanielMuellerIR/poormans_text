#ifndef PMT_PUBLICATION_H
#define PMT_PUBLICATION_H
int pmt_renameat2_noreplace(int source_directory, const char *source, int target_directory, const char *target);
int pmt_remove_staging_at(int parent, const char *name, int expected);
#endif
