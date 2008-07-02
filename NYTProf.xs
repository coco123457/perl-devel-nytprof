/* vim: ts=2 sw=2 sts=0 noexpandtab:
 * ************************************************************************
 * This file is part of the Devel::NYTProf package.
 * Copyright 2008 Adam J. Kaplan, The New York Times Company.
 * Released under the same terms as Perl 5.8
 * See http://search.cpan.org/~akaplan/Devel-NYTProf for more information
 * ************************************************************************
 * $Id$
 * ************************************************************************
 */
#define PERL_NO_GET_CONTEXT		/* we want efficiency */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifndef NO_PPPORT_H
#   define NEED_my_strlcpy
#   define NEED_my_snprintf
#   include "ppport.h"
#endif
#if !defined(OutCopFILE)
#    define OutCopFILE CopFILE
#endif

#if (PERL_VERSION < 8) || ((PERL_VERSION == 8) && (PERL_SUBVERSION < 8))
/* If we're using DB::DB() instead of opcode redirection with an old perl
 * then PL_curcop in DB() will refer to the DB() wrapper in Devel/NYTProf.pm
 * so we'd have to crawl the stack to find the right cop. However, for some
 * reason that I don't pretend to understand the folowing expression works:
 */
#define PL_curcop_nytprof (use_db_sub ? ((cxstack + cxstack_ix)->blk_oldcop) : PL_curcop)
#else
#define PL_curcop_nytprof PL_curcop
#endif

#include <sys/time.h>
#include <stdio.h>
#ifdef HAS_STDIO_EXT_H
#include <stdio_ext.h>
#else
#warning "Not using stdio_ext.h. Add it to INCLUDE path and recompile with -DHAS_STDIO_EXT_H to use it."
#endif

#ifdef HASFPURGE
#define FPURGE(file) fpurge(file)
#elif defined(HAS_FPURGE)
#define FPURGE(file) _fpurge(file)
#elif defined(HAS__FPURGE)
#define FPURGE(file) __fpurge(file)
#else
#define FPURGE(file)
#warning "No fpurge function found -- risk of corrupted profile when forking"
#endif

/* Hash table definitions */
#define MAX_HASH_SIZE 512

typedef struct hash_entry {
	unsigned int id;
	void* next_entry;
	char* key;
	unsigned int key_len;
	unsigned int eval_fid;
	unsigned int eval_line_num;
	char *key_abs;
	void* next_inserted; /* linked list in insertion order */
} Hash_entry;

typedef struct hash_table {
	Hash_entry** table;
	unsigned int size;
	Hash_entry* first_inserted;
	Hash_entry* last_inserted;
} Hash_table;

static Hash_table hashtable = { NULL, MAX_HASH_SIZE, NULL, NULL };
/* END Hash table definitions */

/* defaults */
static FILE* out;
static FILE* in;

/* options and overrides */
static char PROF_output_file[MAXPATHLEN+1] = "nytprof.out";
static bool embed_fid_line = 0;
static bool usecputime = 0;
static bool profile_blocks = 0;
static int use_db_sub = 0;
static int profile_begin = 0;
static int trace_level = 0;

/* time tracking */
static struct tms start_ctime, end_ctime;
#ifdef HAS_GETTIMEOFDAY
static struct timeval start_time, end_time;
#else
static int (*u2time)(pTHX_ UV *) = 0;
static UV start_utime[2], end_utime[2];
#endif
static unsigned int last_executed_line;
static unsigned int last_executed_fid;
static        char *last_executed_fileptr;
static unsigned int last_block_line;
static unsigned int last_sub_line;
static unsigned int is_profiling;
static unsigned int is_finishing;
static pid_t last_pid;

/* reader module variables */
static unsigned int ticks_per_sec = 0; /* 0 forces error if not set */

/* prototypes */
static void write_cached_fids();
void print_header(pTHX);
unsigned int get_file_id(pTHX_ char*, STRLEN, int);
void output_int(unsigned int);
void DB(pTHX);
void set_option(const char*, const char*);
static int enable_profile(pTHX);
static int disable_profile(pTHX);
void open_output_file(pTHX_ char *);
int reinit_if_forked(pTHX);
HV *load_profile_data_from_stream();
AV *store_profile_line_entry(pTHX_ SV *rvav, unsigned int line_num, 
															double time, int count, unsigned int fid);

OP *pp_nextstate_profiler(pTHX); OP *(*pp_nextstate_orig)(pTHX);
OP *pp_setstate_profiler(pTHX);  OP *(*pp_setstate_orig)(pTHX);
OP *pp_dbstate_profiler(pTHX);   OP *(*pp_dbstate_orig)(pTHX);
OP *pp_entersub_profiler(pTHX);  OP *(*pp_entersub_orig)(pTHX);
HV *sub_callers_hv;

/* macros for outputing profile data */
#define OUTPUT_PID() STMT_START { \
	assert(out != NULL); fputc('P', out); output_int(getpid()); output_int(getppid()); \
} STMT_END

#define END_OUTPUT_PID(pid) STMT_START { \
	assert(out != NULL); fputc('p', out); output_int(pid); fflush(out); \
} STMT_END


/***********************************
 * Devel::NYTProf Functions        *
 ***********************************/

/**
 * output file header
 */
void
print_header(pTHX) {
	time_t basetime = PL_basetime;
	unsigned int ticks = (usecputime) ? CLOCKS_PER_SEC : 1000000;

	assert(out != NULL);
	/* File header with "magic" string, with file major and minor version */
	fprintf(out, "NYTProf %d %d\n", 1, 0);
	/* Human readable comments and attributes follow
	 * comments start with '#', end with '\n', and are discarded
	 * attributes start with ':', a word, '=', then the value, then '\n'
	 */
	fprintf(out, "# Perl profile database. Generated by Devel::NYTProf on %s",
		ctime(&basetime)); /* uses \n from ctime to terminate line */

	/* XXX add options, $0, etc, but beware of embedded newlines */
	/* XXX would be good to adopt a proper charset & escaping for these */
	fprintf(out, ":%s=%lu\n",      "basetime",      (unsigned long)PL_basetime); /* $^T */
	fprintf(out, ":%s=%s\n",       "xs_version",    XS_VERSION);
	fprintf(out, ":%s=%d.%d.%d\n", "perl_version",  PERL_REVISION, PERL_VERSION, PERL_SUBVERSION);
	fprintf(out, ":%s=%u\n",       "ticks_per_sec", ticks);

	OUTPUT_PID();

	write_cached_fids(); /* empty initially, non-empty after fork */

	fflush(out);
}

/**
 * An implementation of the djb2 hash function by Dan Bernstein.
 */
unsigned long
hash (char* _str, unsigned int len) {
	char* str = _str;
	unsigned long hash = 5381;

	while (len--) {
		hash = ((hash << 5) + hash) + *str++; /* hash * 33 + c */
	}
	return hash;
}

/**
 * Fetch/Store on hash table.  entry must always be defined. 
 * hash_op will find hash_entry in the hash table.  
 * hash_entry not in table, insert is false: returns NULL
 * hash_entry not in table, insert is true: inserts hash_entry and returns hash_entry
 * hash_entry in table, insert IGNORED: returns pointer to the actual hash entry
 */
char
hash_op (Hash_entry entry, Hash_entry** retval, bool insert) {
	static int next_fid = 1;	/* 0 is reserved */
	unsigned long h = hash(entry.key, entry.key_len) % hashtable.size;

	Hash_entry* found = hashtable.table[h];
	while(NULL != found) {

		if (found->key_len == entry.key_len && 
				strnEQ(found->key, entry.key, entry.key_len)) {
			*retval = found;
			return 0;
		}

		if (NULL == (Hash_entry*)found->next_entry) {
			if (insert) {

				Hash_entry* e;
				Newz(0, e, 1, Hash_entry);
				e->id = next_fid++;
				e->next_entry = NULL;
				e->key_len = entry.key_len;
				e->key = (char*)safemalloc(sizeof(char) * e->key_len + 1);
				e->key[e->key_len] = '\0';
				strncpy(e->key, entry.key, e->key_len);
				found->next_entry = e;
				*retval = (Hash_entry*)found->next_entry;
				if (hashtable.last_inserted)
					hashtable.last_inserted->next_inserted = e;
				hashtable.last_inserted = e;
				return 1;
			} else {
				*retval = NULL;
				return -1;
			}
		}
		found = (Hash_entry*)found->next_entry;
	}

	if (insert) {
		Hash_entry* e;
		Newz(0, e, 1, Hash_entry);
		e->id = next_fid++;
		e->next_entry = NULL;
		e->key_len = entry.key_len;
		e->key = (char*)safemalloc(sizeof(char) * e->key_len + 1);
		e->key[e->key_len] = '\0';
		strncpy(e->key, entry.key, e->key_len);

		*retval =	hashtable.table[h] = e;

		if (!hashtable.first_inserted)
			hashtable.first_inserted = e;
		if (hashtable.last_inserted)
			hashtable.last_inserted->next_inserted = e;
		hashtable.last_inserted = e;

		return 1;
	}

	*retval = NULL;
	return -1;
}


static void
emit_fid (Hash_entry *found) {
	char  *file_name     = found->key;
	STRLEN file_name_len = found->key_len;
	if (found->key_abs) {
		file_name = found->key_abs;
		file_name_len = strlen(file_name);
	}
	fputc('@', out);
	output_int(found->id);
	output_int(found->eval_fid);
	output_int(found->eval_line_num);
	while (file_name_len--)
		fputc(*file_name++, out);
	fputc('\n', out);
}


static void
write_cached_fids() {
	Hash_entry *e = hashtable.first_inserted;
	while (e) {
		emit_fid(e);
		e = (Hash_entry *)e->next_inserted;
	}
}


/**
 * Return a unique persistent id number for a file.
 * If file name has not been seen before
 * then, if create_new is false it returns 0 otherwise it
 * assigns a new id and outputs the file and id to the stream.
 * If the file name is a synthetic name for an eval then
 * get_file_id recurses to process the 'embedded' file name first.
 */
unsigned int
get_file_id(pTHX_ char* file_name, STRLEN file_name_len, int create_new) {

	Hash_entry entry, *found;

	/* AutoLoader adds some information to Perl's internal file name that we have
	   to remove or else the file path will be borked */
	if (')' == file_name[file_name_len - 1]) {
		char* new_end = strstr(file_name, " (autosplit ");
		if (new_end)
			file_name_len = new_end - file_name;
	}
	entry.key = file_name;
	entry.key_len = file_name_len;

	if (1 == hash_op(entry, &found, create_new)) {	/* inserted new entry */

		/* if this is a synthetic filename for an 'eval'
		 * ie "(eval 42)[/some/filename.pl:line]"
		 * then ensure we've already generated an id for the underlying
		 * filename
		 */
		if ('(' == file_name[0] && ']' == file_name[file_name_len-1]) {
			char *start = strchr(file_name, '[');
			const char *colon = ":";
			/* can't use strchr here (not nul terminated) so use rninstr */
			char *end = rninstr(file_name, file_name+file_name_len-1, colon, colon+1);

			if (!start || !end || start > end) {
				warn("Unsupported filename syntax '%s'", file_name);
				return 0;
			}
			++start; /* move past [ */
			found->eval_fid = get_file_id(aTHX_ start, end - start, create_new);	/* recurse */
			found->eval_line_num = atoi(end+1);
		}

		/* determine absolute path if file_name is relative */
		found->key_abs = NULL;
		if (!found->eval_fid && *file_name != '/') {
			char file_name_abs[MAXPATHLEN * 2];
			/* Note that the current directory may have changed
			 * between loading the file and profiling it.
			 * We don't use realpath() or similar here because we want to
			 * keep the of symlinks etc. as the program saw them.
			 */
			if (!getcwd(file_name_abs, sizeof(file_name_abs))) {
				warn("getcwd: %s\n", strerror(errno)); /* eg permission */
			}
			else if (strNE(file_name_abs, "/")) {
				if (strnEQ(file_name, "./", 2))
					++file_name;
				else
					strcat(file_name_abs, "/");
				strncat(file_name_abs, file_name, file_name_len);
				found->key_abs = strdup(file_name_abs);
			}
		}

		emit_fid(found);

		if (trace_level) {
			/* including last_executed_fid can be handy for tracking down how
			 * a file got loaded */
			if (found->eval_fid)
				warn("New fid %2u (after %2u:%-4u): %.*s (eval fid %u line %u)\n",
					found->id, last_executed_fid, last_executed_line,
					found->key_len, found->key, found->eval_fid, found->eval_line_num);
		  else
				warn("New fid %2u (after %2u:%-4u): %.*s %s\n",
					found->id, last_executed_fid, last_executed_line,
					found->key_len, found->key, (found->key_abs) ? found->key_abs : "");
		}
	}
  else if (trace_level >= 4) {
		if (found)
		     warn("fid %d: %.*s\n",   found->id, found->key_len, found->key);
		else warn("fid %d: %.*s NOT FOUND\n", 0,  entry.key_len,  entry.key);
	}

	return (found) ? found->id : 0;
}


/**
 * Output an integer in bytes. That is, output the number in binary, using the
 * least number of bytes possible.  All numbers are positive. Use sign slot as
 * a marker
 */
void output_int(unsigned int i) {

	/* general case. handles all integers */
	if (i < 0x80) { /* < 8 bits */
		fputc( (char)i, out);
	}
	else if (i < 0x4000) { /* < 15 bits */
		fputc( (char)((i >> 8) | 0x80), out);
		fputc( (char)i, out);
	}
	else if (i < 0x200000) { /* < 22 bits */
		fputc( (char)((i >> 16) | 0xC0), out);
		fputc( (char)(i >> 8), out);
		fputc( (char)i, out);
	}
	else if (i < 0x10000000)  { /* 32 bits */
		fputc( (char)((i >> 24) | 0xE0), out);
		fputc( (char)(i >> 16), out);
		fputc( (char)(i >> 8), out);
		fputc( (char)i, out);
	}
	else {	/* need all the bytes. */
		fputc( 0xFF, out);
		fputc( (char)(i >> 24), out);
		fputc( (char)(i >> 16), out);
		fputc( (char)(i >> 8), out);
		fputc( (char)i, out);
	}
}


static const char* block_type[] = {
    "NULL",
    "SUB",
    "EVAL",
    "LOOP",
    "SUBST",
    "BLOCK",
};


/* based on S_dopoptosub_at() from perl pp_ctl.c */
static int
dopopcx_at(pTHX_ PERL_CONTEXT *cxstk, I32 startingblock, UV stop_at)
{
    I32 i;
    register PERL_CONTEXT *cx;
    for (i = startingblock; i >= 0; i--) {
        UV type_bit;
        cx = &cxstk[i];
        type_bit = 1 << CxTYPE(cx);
        if (type_bit & stop_at)
            return i;
    }
    return i; /* == -1 */
}


static COP *
start_cop_of_context(pTHX_ PERL_CONTEXT *cx) {
    OP *start_op, *o;
    int type;

    switch (CxTYPE(cx)) {
    case CXt_EVAL:
        start_op = (OP*)cx->blk_oldcop;
        break;
    case CXt_FORMAT:
        start_op = CvSTART(cx->blk_sub.cv);
        break;
    case CXt_SUB:
        start_op = CvSTART(cx->blk_sub.cv);
        break;
    case CXt_LOOP:
#if (PERL_VERSION < 10)
        start_op = cx->blk_loop.redo_op;
#else
        start_op = cx->blk_loop.my_op->op_redoop;
#endif
        break;
    case CXt_BLOCK:
				/* this will be NULL for the top-level 'main' block */
        start_op = (OP*)cx->blk_oldcop;
        break;
    case CXt_SUBST:			/* FALLTHRU */
    case CXt_NULL:			/* FALLTHRU */
		default:
        start_op = NULL;
        break;
    }
    if (!start_op) {
        if (trace_level >= 4)
            warn("\tstart_cop_of_context: can't find start of %s\n", 
            			block_type[CxTYPE(cx)]);
        return NULL;
    }
    /* find next cop from OP */
		o = start_op;
    while ( o && (type = (o->op_type) ? o->op_type : o->op_targ) ) {
        if (type == OP_NEXTSTATE || type == OP_SETSTATE || type == OP_DBSTATE) {
				  if (trace_level >= 4)
						warn("\tstart_cop_of_context %s is %s line %d of %s\n",
							block_type[CxTYPE(cx)], OP_NAME(o), CopLINE((COP*)o), 
							OutCopFILE((COP*)o));
					return (COP*)o;
				}
        /* should never get here? */
        if (1 || trace_level)
            warn("\tstart_cop_of_context %s op '%s' isn't a cop", 
            			block_type[CxTYPE(cx)], OP_NAME(o));
        if (trace_level >= 4)
            do_op_dump(1, PerlIO_stderr(), o);
        o = o->op_next;
    }
    if (trace_level >= 3) {
			warn("\tstart_cop_of_context: can't find next cop for %s line %d\n",
					block_type[CxTYPE(cx)], CopLINE(PL_curcop));
			do_op_dump(1, PerlIO_stderr(), start_op);
		}
    return NULL;
}

static PERL_CONTEXT *
visit_contexts(pTHX_ UV stop_at, int (*callback)(pTHX_ PERL_CONTEXT *cx, 
								UV *stop_at_ptr)) 
{
    /* modelled on pp_caller() in pp_ctl.c */
    register I32 cxix = cxstack_ix;
    register PERL_CONTEXT *cx = NULL;
    register PERL_CONTEXT *ccstack = cxstack;
    PERL_SI *top_si = PL_curstackinfo;

    if (trace_level >= 4)
        warn("visit_contexts: \n");

    while (1) {
        /* we may be in a higher stacklevel, so dig down deeper */
				/* XXX so we'll miss code in sort blocks and signals?		*/
				/* callback should perhaps be moved to dopopcx_at */
        while (cxix < 0 && top_si->si_type != PERLSI_MAIN) {
            if (trace_level >= 3)
							warn("Not on main stack (type %d); digging top_si %p->%p, ccstack %p->%p\n",
										top_si, top_si->si_prev, ccstack, top_si->si_cxstack);
            top_si  = top_si->si_prev;
            ccstack = top_si->si_cxstack;
            cxix = dopopcx_at(aTHX_ ccstack, top_si->si_cxix, stop_at);
        }
        if (cxix < 0 || (cxix == 0 && !top_si->si_prev)) {
						/* cxix==0 && !top_si->si_prev => top-level BLOCK */
						if (trace_level >= 4)
								warn("visit_contexts: reached top of context stack\n");
						return NULL;
        }
        cx = &ccstack[cxix];
        if (trace_level >= 4)
					warn("visit_context: %s cxix %d (si_prev %p)\n",
							block_type[CxTYPE(cx)], cxix, top_si->si_prev);
				if (callback(aTHX_ cx, &stop_at))
					return cx;
        /* no joy, look further */
        cxix = dopopcx_at(aTHX_ ccstack, cxix - 1, stop_at);
    }
    return NULL; /* not reached */
}


static int
_cop_in_same_file(COP *a, COP *b)
{
  int same = 0;
	if (OutCopFILE(a) == OutCopFILE(b))
		same = 1;
	else
	/* fallback to strEQ, surprisingly common (check why) XXX expensive */
  if (strEQ(OutCopFILE(a), OutCopFILE(b)))
		same = 1;
  return same;
}


int
_check_context(pTHX_ PERL_CONTEXT *cx, UV *stop_at_ptr)
{
		COP *near_cop;
		PERL_UNUSED_ARG(stop_at_ptr);

		if (CxTYPE(cx) == CXt_SUB) {
				if (PL_debstash && CvSTASH(cx->blk_sub.cv) == PL_debstash)
					return 0; /* skip subs in DB package */

				near_cop = start_cop_of_context(aTHX_ cx);

				/* only use the cop if it's in the same file */
				if (_cop_in_same_file(near_cop, PL_curcop)) {
					last_sub_line = CopLINE(near_cop);
					/* treat sub as a block if we've not found a block yet */
					if (!last_block_line)
							last_block_line = last_sub_line;
				}

				if (trace_level >= 4) {
					GV *sv = CvGV(cx->blk_sub.cv);
					warn("\tat %d: block %d sub %d for %s %s\n",
						last_executed_line, last_block_line, last_sub_line,
						block_type[CxTYPE(cx)], (sv) ? GvNAME(sv) : "");
					if (trace_level >= 9)
						sv_dump((SV*)cx->blk_sub.cv);
				}

				return 1;		/* stop looking */
		}

	/* NULL, EVAL, LOOP, SUBST, BLOCK context */
	if (trace_level >= 4)
		warn("\t%s\n", block_type[CxTYPE(cx)]);

	/* if we've got a block line, skip this context and keep looking for a sub */
	if (last_block_line)
		return 0;

	/* if we can't get a line number for this context, skip it */
	if ((near_cop = start_cop_of_context(aTHX_ cx)) == NULL)
		return 0;

	/* if this context is in a different file... */
	if (!_cop_in_same_file(near_cop, PL_curcop)) {
		/* if we started in a string eval ... */
		if ('(' == *OutCopFILE(PL_curcop)) {
			/* give up XXX could do better here */
			last_block_line = last_sub_line = last_executed_line;
			return 1;
		}
		/* shouldn't happen! */
		if (trace_level >= 1)
			warn("at %d: %s in different file (%s, %s)",
						last_executed_line, block_type[CxTYPE(cx)], 
						OutCopFILE(near_cop), OutCopFILE(PL_curcop));
		return 1; /* stop looking */
	}

	last_block_line = CopLINE(near_cop);
	if (trace_level >= 4)
		warn("\tat %d: block %d for %s\n",
			last_executed_line, last_block_line, block_type[CxTYPE(cx)]);
	return 0;
}

/* copied from perl's S_closest_cop in util.c as used by warn(...) */

static const COP*
closest_cop(pTHX_ const COP *cop, const OP *o)
{
    dVAR;
    /* Look for PL_op starting from o.  cop is the last COP we've seen. */
    if (!o || o == PL_op)
        return cop;
    if (o->op_flags & OPf_KIDS) {
        const OP *kid;
        for (kid = cUNOPo->op_first; kid; kid = kid->op_sibling) {
            const COP *new_cop;
            /* If the OP_NEXTSTATE has been optimised away we can still use it
             * the get the file and line number. */
            if (kid->op_type == OP_NULL && kid->op_targ == OP_NEXTSTATE)
                cop = (const COP *)kid;
            /* Keep searching, and return when we've found something. */
            new_cop = closest_cop(aTHX_ cop, kid);
            if (new_cop)
                return new_cop;
        }
    }
    /* Nothing found. */
    return NULL;
}


/**
 * PerlDB implementation. Called before each breakable statement
 */
void
DB(pTHX) {
	char *file;
	unsigned int elapsed;
	COP *cop;

	if (usecputime) {
		times(&end_ctime);
		elapsed = end_ctime.tms_utime - start_ctime.tms_utime
						+ end_ctime.tms_stime - start_ctime.tms_stime;
	} else {
#ifdef HAS_GETTIMEOFDAY
		gettimeofday(&end_time, NULL);
		elapsed = (end_time.tv_sec - start_time.tv_sec) * 1000000
						+ end_time.tv_usec - start_time.tv_usec;
#else
		(*u2time)(aTHX_ end_utime);
		elapsed = (end_utime[0] - start_utime[0]) * 1000000
						+ end_utime[1] - start_utime[1];
#endif
	}

	if (!out)
		return;

	if (!is_profiling)
		return;

	if (last_executed_fid) {
		reinit_if_forked(aTHX);

		fputc( (profile_blocks) ? '*' : '+', out);
		output_int(elapsed);
		output_int(last_executed_fid);
		output_int(last_executed_line);
		if (profile_blocks) {
			output_int(last_block_line);
			output_int(last_sub_line);
		}
		if (trace_level >= 3)
			warn("Wrote %d:%-4d %2u ticks (%u, %u)\n", last_executed_fid, 
						last_executed_line, elapsed, last_block_line, last_sub_line);

	}

	cop = PL_curcop_nytprof;
	if ( (last_executed_line = CopLINE(cop)) == 0 ) {
		/* Might be a cop that has been optimised away.  We can try to find such a
		 * cop by searching through the optree starting from the sibling of PL_curcop.
		 * See Perl_vmess in perl's util.c for how warn("...") finds the line number.
		 */
		cop = closest_cop(aTHX_ cop, cop->op_sibling);
		if (!cop)
			cop = PL_curcop_nytprof;
		last_executed_line = CopLINE(cop);
		if (!last_executed_line) { /* typically when _finish called by END */
			if (!is_finishing)
				warn("Unable to determine line number in %s", OutCopFILE(cop));
			last_executed_line = 1; /* don't want zero line numbers in data */
		}
	}

	file = OutCopFILE(cop);
	if (!last_executed_fid) {	/* first time */
		if (trace_level >= 1) {
			warn("NYTProf pid %d: first statement line %d of %s",
				getpid(), CopLINE(cop), OutCopFILE(cop));
		}
	}
	if (file != last_executed_fileptr) {
		last_executed_fileptr = file;
		last_executed_fid = get_file_id(aTHX_ file, strlen(file), 1);
	}

	if (trace_level >= 4)
		warn("     @%d:%-4d %s", last_executed_fid, last_executed_line,
			(profile_blocks) ? "looking for block and sub lines" : "");

	if (profile_blocks) {
		last_block_line = 0;
		last_sub_line   = 0;
		visit_contexts(aTHX_ ~0, &_check_context);
		/* if we didn't find block or sub scopes then use current line */
		if (!last_block_line) last_block_line = last_executed_line;
		if (!last_sub_line)   last_sub_line   = last_executed_line;
	}

	if (usecputime) {
		times(&start_ctime);
	} else {
#ifdef HAS_GETTIMEOFDAY
		gettimeofday(&start_time, NULL);
#else
		start_utime[2];
		(*u2time)(aTHX_ start_utime);
#endif
	}
}

/**
 * Sets or toggles the option specified by 'option'. 
 */
void
set_option(const char* option, const char* value) {

	if (strEQ(option, "file")) {
		strncpy(PROF_output_file, value, MAXPATHLEN);
	}
	else if (strEQ(option, "usecputime")) {
		usecputime = 1;
	}
	else if (strEQ(option, "begin")) {
		profile_begin = atoi(value);
	}
	else if (strEQ(option, "blocks")) {
		profile_blocks = 1;
	}
	else if (strEQ(option, "expand")) {
		embed_fid_line = 1;
	}
	else if (strEQ(option, "trace")) {
		trace_level = atoi(value);
	}
	else if (strEQ(option, "use_db_sub")) {
		use_db_sub = atoi(value);
	}
	else {
		warn("Unknown option: %s\n", option);
		return;
	}
	if (trace_level)
		warn("# %s=%s\n", option, value);
}

/**
 * Open the output file. This is encapsulated because the code can be reused
 * without the environment parsing overhead after each fork.
 */
void
open_output_file(pTHX_ char *filename) {

  char filename_buf[MAXPATHLEN];

	if (out) {	/* already opened so assume forking */
		sprintf(filename_buf, "%s.%d", filename, getpid());
		filename = filename_buf;
		/* caller is expected to have purged/closed old out if appropriate */
	}

	out = fopen(filename, "wb");
	if (!out) {
		disable_profile(aTHX);
		croak("Failed to open output '%s': %s", filename, strerror(errno));
	}
	if (trace_level)
			warn("Opened %s\n", filename);

	print_header(aTHX);
}


int
reinit_if_forked(pTHX) {
	if (getpid() == last_pid)
		return 0;		/* not forked */
	if (trace_level >= 1)
		warn("New pid %d (was %d)\n", getpid(), last_pid);
	last_pid = getpid();
	last_executed_fileptr = NULL;
	FPURGE(out);
  /* we don't bother closing the current out fh so if we don't have fpurge
	* any old pending data that was duplicated by the fork won't be written
	* until the program exits and that'll be much easier to handle by the reader
	*/
	open_output_file(aTHX_ PROF_output_file);
	return 1;		/* have forked */
}


/************************************
 * Sub caller tracking
 ************************************/

OP *
pp_entersub_profiler(pTHX) {
	OP *op;
	COP *prev_cop = PL_curcop;
	OP *next_op = PL_op->op_next; /* op to execute after sub returns */
	dSP;
	SV *sub_sv = *SP;

	/*
	 * for normal subs pp_entersub enters the sub
	 * and returns the first op *within* the sub (typically a dbstate).
	 * for XS subs pp_entersub executes the entire sub
	 * and returning the op *after* the sub (PL_op->op_next)
	 */
	op = pp_entersub_orig(aTHX);

	if (is_profiling) {

		/* get line, file, and fid for statement *before* the call */
		char *file = OutCopFILE(prev_cop);
		int line = CopLINE(prev_cop);
		unsigned int fid = get_file_id(aTHX_ file, strlen(file), 1);
		char fid_line_key[50];
		int fid_line_key_len = my_snprintf(fid_line_key, sizeof(fid_line_key), "%u:%d", fid, line);
		SV *subname_sv = newSV(0);
		SV *sv_tmp;
		CV *cv;

		if (op != next_op) { /* have entered a sub */
			/* use cv of sub we've just entered to get name */
			sub_sv = (SV *)cxstack[cxstack_ix].blk_sub.cv;
		}
		/* else have returned from XS so use sub_sv for name */

		/* determine the original fully qualified name for sub */
		/* XXX hacky with lots of obscure edge cases */
		/* basically needs to be clone of first part of pp_entersub, but isn't */
		if (SvROK(sub_sv))
			sub_sv = SvRV(sub_sv);
		cv = (isGV(sub_sv)) ? GvCV(sub_sv) : (SvTYPE(sub_sv) == SVt_PVCV) ? (CV *)sub_sv : NULL;
		if (cv && CvGV(cv) && GvSTASH(CvGV(cv))) {
			/* for a plain call of an imported sub the GV is of the current
				* package, so we dig to find the original package
				*/
			GV *gv = CvGV(cv);
			sv_setpvf(subname_sv, "%s::%s", HvNAME(GvSTASH(gv)), GvNAME(gv));
		}
		else if (isGV(sub_sv)) {
			gv_efullname3(subname_sv, (GV *)sub_sv, Nullch);
		}
		else if (SvTYPE(sub_sv) == SVt_PVCV) {
			/* unnamed CV, e.g. seen in mod_perl. XXX do better? */
			sv_setpvn(subname_sv, "__ANON__", 8);
		}
		else if (SvTYPE(sub_sv) == SVt_PV
				/* Errno.pm does &$errname and sub_sv is PVIV! with POK */
			|| SvPOK(sub_sv)
		) {
			sv_setsv(subname_sv, sub_sv);
		}
		else {
			char *what = (op == next_op) ? "xs" : "sub";
			warn("unknown entersub %s '%s'", what, SvPV_nolen(sub_sv));
			if (trace_level || 1)
				sv_dump(sub_sv);
			sv_setpvf(subname_sv, "(unknown %s %s)", what, SvPV_nolen(sub_sv));
		}

		if (trace_level >= 3)
			fprintf(stderr, "fid %d:%d called %s (%s)\n", fid, line, 
							SvPV_nolen(subname_sv), OP_NAME(op));

		/* { subname => { "fid:line" => count } } */
		sv_tmp = *hv_fetch(sub_callers_hv, SvPV_nolen(subname_sv), 
												SvCUR(subname_sv), 1);
		if (!SvROK(sv_tmp)) /* autoviv */
			sv_setsv(sv_tmp, newRV_noinc((SV*)newHV()));
		sv_tmp = *hv_fetch((HV*)SvRV(sv_tmp), fid_line_key, fid_line_key_len, 1);
		sv_inc(sv_tmp);
	}

	return op;
}

OP *
pp_nextstate_profiler(pTHX) { OP *op=pp_nextstate_orig(aTHX); DB(aTHX); return op; }
OP *
pp_setstate_profiler(pTHX) {  OP *op=pp_setstate_orig(aTHX);  DB(aTHX); return op; }
OP *
pp_dbstate_profiler(pTHX) {   OP *op=pp_dbstate_orig(aTHX);   DB(aTHX); return op; }


/************************************
 * Shared Reader,NYTProf Functions  *
 ************************************/

static int
enable_profile(pTHX)
{
	int prev_is_profiling = is_profiling;
	if (trace_level)
		warn("NYTProf enable_profile%s", (prev_is_profiling)?" (already enabled)":"");
	is_profiling = 1;
	last_executed_fileptr = NULL;
	if (use_db_sub)
		sv_setiv(PL_DBsingle, 1);
	return prev_is_profiling;
}

static int
disable_profile(pTHX)
{
	int prev_is_profiling = is_profiling;
	sv_setiv(PL_DBsingle, 0);
	is_profiling = 0;
	if (out)
		fflush(out);
	if (trace_level)
		warn("NYTProf disable_profile");
	return prev_is_profiling;
}

/* Initial setup */
int
init_profiler(pTHX) {
	unsigned int hashtable_memwidth;

	/* Save the process id early. We can monitor it to detect forks that affect 
		 output buffering.
		 NOTE: don't fork before calling the xsloader obviously! */
	last_pid = getpid();
	is_finishing = 0;

	if (trace_level)
		warn("NYTProf init pid %d\n", last_pid);

	if (get_hv("DB::sub", 0) == NULL) {
		warn("NYTProf internal error - perl not in debug mode");
		return 0;
	}

	/* create file id mapping hash */
	hashtable_memwidth = sizeof(Hash_entry*) * hashtable.size;
	hashtable.table = (Hash_entry**)safemalloc(hashtable_memwidth);
	memset(hashtable.table, 0, hashtable_memwidth);
	
	open_output_file(aTHX_ PROF_output_file);

	/* redirect opcodes for statement profiling */
	if (!use_db_sub) {
		pp_nextstate_orig = PL_ppaddr[OP_NEXTSTATE];
		PL_ppaddr[OP_NEXTSTATE] = pp_nextstate_profiler;
		pp_setstate_orig = PL_ppaddr[OP_SETSTATE];
		PL_ppaddr[OP_SETSTATE] = pp_setstate_profiler;
		pp_dbstate_orig = PL_ppaddr[OP_DBSTATE];
		PL_ppaddr[OP_DBSTATE] = pp_dbstate_profiler;
	}

	/* redirect opcodes for caller tracking */
	if (!sub_callers_hv)
		sub_callers_hv = newHV();
	pp_entersub_orig = PL_ppaddr[OP_ENTERSUB];
	PL_ppaddr[OP_ENTERSUB] = pp_entersub_profiler;

	if (profile_begin) {
		enable_profile(aTHX);
	}
	else {
		SV *enable_profile_sv = (SV *)get_cv("DB::enable_profile", GV_ADDWARN);
		if (trace_level >= 2)
			warn("enable_profile defered to INIT phase");
		/* INIT { enable_profile() } */
		if (!PL_initav)
			PL_initav = newAV();
		av_unshift(PL_initav, 1); /* we want to be first */
		av_store(PL_initav, 0, SvREFCNT_inc(enable_profile_sv));
	}

	/* END { _finish() } */
	if (!PL_endav)
		PL_endav = newAV();
	av_push(PL_endav, (SV *)get_cv("DB::_finish", GV_ADDWARN));

	/* seed first run time */
	if (usecputime) {
		times(&start_ctime);
	} else {
#ifdef HAS_GETTIMEOFDAY
		gettimeofday(&start_time, NULL);
#else
		SV **svp = hv_fetch(PL_modglobal, "Time::U2time", 12, 0);
		if (!svp || !SvIOK(*svp)) croak("Time::HiRes is required");
		u2time = INT2PTR(int(*)(pTHX_ UV*), SvIV(*svp));
		(*u2time)(aTHX_ start_utime);
#endif
	}
  return 1;
}

/************************************
 * Devel::NYTProf::Reader Functions *
 ************************************/

void
add_entry(pTHX_ AV *dest_av, unsigned int file_num, unsigned int line_num,			
					double time, unsigned int eval_file_num, unsigned int eval_line_num) 
{
  /* get ref to array of per-line data */
  unsigned int fid = (eval_line_num) ? eval_file_num : file_num;
	SV *line_time_rvav = *av_fetch(dest_av, fid, 1);

	if (!SvROK(line_time_rvav))		/* autoviv */
			sv_setsv(line_time_rvav, newRV_noinc((SV*)newAV()));

  if (!eval_line_num) {
		store_profile_line_entry(aTHX_ line_time_rvav, line_num, time, 1, fid);
	}
	else {
		/* times for statements executed *within* a string eval are accumulated
		 * embedded nested within the line the eval is on but without increasing
		 * the time or count of the eval itself. Instead the time and count is
		 * accumulated for each line within the eval on an embedded array reference.
		 */
		AV *av = store_profile_line_entry(aTHX_ line_time_rvav, eval_line_num, 0, 0, fid);

		SV *eval_line_time_rvav = *av_fetch(av, 2, 1);
		if (!SvROK(eval_line_time_rvav))		/* autoviv */
				sv_setsv(eval_line_time_rvav, newRV_noinc((SV*)newAV()));

		store_profile_line_entry(aTHX_ eval_line_time_rvav, line_num, time, 1, fid);
	}
}


AV *
store_profile_line_entry(pTHX_ SV *rvav, unsigned int line_num, double time, 
													int count, unsigned int fid)
{
	SV *time_rvav = *av_fetch((AV*)SvRV(rvav), line_num, 1);
	AV *line_av;
	if (!SvROK(time_rvav)) {		  /* autoviv */
		line_av = newAV();
		sv_setsv(time_rvav, newRV_noinc((SV*)line_av));
		av_store(line_av, 0, newSVnv(time));
		av_store(line_av, 1, newSViv(count));
		/* if eval then   2  is used for lines within the string eval */
		if (embed_fid_line) {	/* used to optimize reporting */
			av_store(line_av, 3, newSVuv(fid));
			av_store(line_av, 4, newSVuv(line_num));
		}
	}
	else {
		SV *time_sv;
		line_av = (AV*)SvRV(time_rvav);
		time_sv = *av_fetch(line_av, 0, 1);
		sv_setnv(time_sv, time + SvNV(time_sv));
		if (count) {
		  SV *sv = *av_fetch(line_av, 1, 1);
			(count == 1) ? sv_inc(sv) : sv_setiv(sv, time + SvIV(sv));
		}
	}
	return line_av;
}


void
write_sub_line_ranges(pTHX_ int fids_only) {
	char *sub_name;
	I32 sub_name_len;
	SV *file_lines_sv;
	HV *hv = GvHV(PL_DBsub);

	if (trace_level >= 2)
		warn("writing sub line ranges\n");

	hv_iterinit(hv);
	while (NULL != (file_lines_sv = hv_iternextsv(hv, &sub_name, &sub_name_len))) 
	{
		char *file_lines = SvPV_nolen(file_lines_sv); /* "filename:first-last" */
		char *first = strrchr(file_lines, ':');
		char *last = (first) ? strchr(first, '-') : NULL;
		unsigned int fid;
		UV first_line, last_line;

		if (!first || !last || !grok_number(first+1, last-first-1, &first_line)) {
			warn("Can't parse %%DB::sub entry for %s '%s'\n", sub_name, file_lines);
			continue;
		} 
		last_line = atoi(++last);

		if (!first_line && !last_line && strstr(sub_name, "::BEGIN"))
			continue;	/* no point writing these */

		fid = get_file_id(aTHX_ file_lines, first - file_lines, 0);
		if (!fid)  /* no point in writing subs in files we've not profiled */
			continue;
		if (fids_only)  /* caller just wants fids assigned */
			continue;

		if (trace_level >= 2)
			warn("Sub %s fid %u lines %u..%u\n", sub_name, fid, first_line, 
																					last_line);

		fputc('s', out);
		output_int(fid);
		output_int(first_line);
		output_int(last_line);
		fputs(sub_name, out);
		fputc('\n', out);
	}
}


void
write_sub_callers(pTHX) {
	char *sub_name;
	I32 sub_name_len;
	SV *fid_line_rvhv;

	if (!sub_callers_hv)
		return;
	if (trace_level >= 2)
		warn("writing sub callers\n");

	hv_iterinit(sub_callers_hv);
	while (NULL != (fid_line_rvhv = hv_iternextsv(sub_callers_hv, &sub_name, 
									&sub_name_len))) 
	{
		HV *fid_lines_hv = (HV*)SvRV(fid_line_rvhv);
		char *fid_line_string;
		I32 fid_line_len;
		SV *sv;

		hv_iterinit(fid_lines_hv);
		while (NULL != (sv = hv_iternextsv(fid_lines_hv, &fid_line_string,
										&fid_line_len))) 
		{
			IV count = SvIV(sv);
			unsigned int fid = 0;
			unsigned int line = 0;
			sscanf(fid_line_string, "%u:%u", &fid, &line);
			if (trace_level >= 3)
				warn("%s called by %u:%u: count %d\n", sub_name, fid, line, count);

			fputc('c', out);
			output_int(fid);
			output_int(line);
			output_int(count);
			fputs(sub_name, out);
			fputc('\n', out);
		}
	}
}


/**
 * Read an integer by decompressing the next 1 to 4 bytes of binary into a 32-
 * bit integer. See output_int() for the compression details.
 */
unsigned int
read_int() {

	static unsigned char d;
	static unsigned int newint;

	d = fgetc(in);
	if (d < 0x80) { /* 7 bits */
		newint = d;
	}
	else if (d < 0xC0) { /* 14 bits */
		newint = d & 0x7F;
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
	} 
	else if (d < 0xE0) { /* 21 bits */
		newint = d & 0x1F;
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
	} 
	else if (d < 0xFF) { /* 28 bits */
		newint = d & 0xF;
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
	} 
	else if (d == 0xFF) { /* 32 bits */
		newint = (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
	}
        return newint;
}

/**
 * Process a profile output file and return the results in a hash like
 * { fid_filename  => [ filename, filename, ... ], # index by [fid]
 *   fid_line_time  => [ [...],[...],..  ] # index by [fid][line]
 * }
 * The value of each [fid][line] is an array ref containing:
 * [ number of calls, total time spent ]
 * lines containing string evals also get an extra element
 * [ number of calls, total time spent, [...] ]
 * which is an reference to an array containing the [calls,time]
 * data for each line of the string eval.
 */
HV*
load_profile_data_from_stream() {
	dTHX; 
	int file_major, file_minor;

	unsigned long input_line = 0L;
	unsigned int file_num;
	unsigned int line_num;
	unsigned int ticks;
	char text[MAXPATHLEN*2];
	int c; /* for while loop */
	HV *profile_hv;
	HV *live_pids_hv = newHV();
	HV *attr_hv = newHV();
	AV* fid_filename_av = newAV();
	AV* fid_line_time_av = newAV();
	AV* fid_block_time_av = NULL;
	AV* fid_sub_time_av = NULL;
	HV* sub_fid_lines_hv = NULL;
	HV* sub_callers_hv = NULL;

	av_extend(fid_filename_av, 64);  /* grow it up front. */
	av_extend(fid_line_time_av, 64);

	if (2 != fscanf(in, "NYTProf %d %d\n", &file_major, &file_minor)) {
		croak("Profile format error while parsing header");
	}
	if (file_major != 1)
		croak("Profile format version %d.%d not supported", file_major, file_minor);

	while (EOF != (c = fgetc(in))) {
		input_line++;
		if (trace_level >= 4)
			warn("Token %lu is %d ('%c') at %ld\n", input_line, c, c, ftell(in)-1);

		switch (c) {
			case '*':			/*FALLTHRU*/
			case '+':
			{
				SV *filename_sv;
				double seconds;
				unsigned int eval_file_num = 0;
				unsigned int eval_line_num = 0;

				ticks    = read_int();
				seconds  = (double)ticks / ticks_per_sec;
				file_num = read_int();
				line_num = read_int();

				filename_sv = *av_fetch(fid_filename_av, file_num, 1);
				if (!SvOK(filename_sv)) {
				  warn("File id %u used but not defined", file_num);
					sv_setsv(filename_sv, &PL_sv_no); /* defined but false, as marker */
				}
				else if (SvROK(filename_sv)) {	/* is an eval */
					AV *av = (AV*)SvRV(filename_sv);
					eval_file_num = SvUV(*av_fetch(av,1,1));
					eval_line_num = SvUV(*av_fetch(av,2,1));
					file_num = eval_file_num;
				}

				add_entry(aTHX_ fid_line_time_av, file_num, line_num,
						seconds, eval_file_num, eval_line_num);
				if (trace_level >= 3)
						warn("Read %d:%-4d %2u ticks\n", file_num, line_num, ticks);

				if (c == '*') {
					unsigned int block_line_num = read_int();
					unsigned int sub_line_num   = read_int();

					if (!fid_block_time_av)
						fid_block_time_av = newAV();
					add_entry(aTHX_ fid_block_time_av, file_num, block_line_num,
							seconds, eval_file_num, eval_line_num);

					if (!fid_sub_time_av)
						fid_sub_time_av = newAV();
					add_entry(aTHX_ fid_sub_time_av, file_num, sub_line_num,
							seconds, eval_file_num, eval_line_num);

					if (trace_level >= 3)
							warn("\tblock %u, sub %u\n", block_line_num, sub_line_num);
				}

				break;
			}

			case '@':
			{
				SV *fid_info_sv;
				unsigned int eval_file_num;
				unsigned int eval_line_num;

				file_num = read_int();
				eval_file_num = read_int();
				eval_line_num = read_int();

				if (NULL == fgets(text, sizeof(text), in))
					/* probably EOF */
					croak("Profile format error while reading fid declaration"); 
				if (trace_level) {
						if (eval_file_num)
							warn("Fid %2u is %.*s (eval fid %u line %u)\n",
									file_num, strlen(text)-1, text, eval_file_num, eval_line_num);
						else
							warn("Fid %2u is %.*s\n",
									file_num, strlen(text)-1, text);
				}

				if (av_exists(fid_filename_av, file_num)
						&& strnNE(SvPV_nolen(AvARRAY(fid_filename_av)[file_num]), text, 
											strlen(text)-1)
				) {
					warn("File id %d redefined from %s to %s", file_num,
								SvPV_nolen(AvARRAY(fid_filename_av)[file_num]), text);
				}

				fid_info_sv = newSVpvn(text, strlen(text)-1); /* drop newline */
				if (eval_line_num) {
					/* change fid_info_sv to ref to array of 
					 * [ name, eval_file_num, eval_line_num ] 
					 */
					AV *av = newAV();
					av_store(av, 0, fid_info_sv);
					av_store(av, 1, newSVuv(eval_file_num));
					av_store(av, 2, newSVuv(eval_line_num));
				  fid_info_sv = newRV_noinc((SV*)av);
				}

				av_store(fid_filename_av, file_num, fid_info_sv);
				break;
			}

			case 's':	/* subroutine file line range */
			{
				SV *sv;
				AV *av;
				unsigned int fid        = read_int();
				unsigned int first_line = read_int();
				unsigned int last_line  = read_int();
				if (NULL == fgets(text, sizeof(text), in))
					croak("Profile format error in sub line range"); /* probably EOF */
				if (trace_level >= 3)
				    warn("Sub %.*s fid %u lines %u..%u\n",
							strlen(text)-1, text, fid, first_line, last_line);
				if (!sub_fid_lines_hv)
					sub_fid_lines_hv = newHV();
				/* { 'pkg::sub' => [ fid, first_line, last_line ], ... } */
				sv = *hv_fetch(sub_fid_lines_hv, text, strlen(text)-1, 1);
				if (!SvROK(sv))		/* autoviv */
						sv_setsv(sv, newRV_noinc((SV*)newAV()));
				av = (AV*)SvRV(sv);
				av_store(av, 0, newSVuv(fid));
				av_store(av, 1, newSVuv(first_line));
				av_store(av, 2, newSVuv(last_line));
				break;
			}

			case 'c':	/* sub callers */
			{
				SV *sv;
				int len;
				unsigned int fid   = read_int();
				unsigned int line  = read_int();
				unsigned int count = read_int();
				if (NULL == fgets(text, sizeof(text), in))
					croak("Profile format error in sub line range"); /* probably EOF */

				if (trace_level >= 3)
				    warn("Sub %.*s called by fid %u line %u: count %d\n",
							strlen(text)-1, text, fid, line, count);

				if (!sub_callers_hv)
					sub_callers_hv = newHV();
				/* { 'pkg::sub' => { fid => { line => count } } } */
				sv = *hv_fetch(sub_callers_hv, text, strlen(text)-1, 1);
				if (!SvROK(sv))		/* autoviv */
						sv_setsv(sv, newRV_noinc((SV*)newHV()));

				len = my_snprintf(text, sizeof(text), "%u", fid);
				sv = *hv_fetch((HV*)SvRV(sv), text, len, 1);
				if (!SvROK(sv)) /* autoviv */
					sv_setsv(sv, newRV_noinc((SV*)newHV()));

				len = my_snprintf(text, sizeof(text), "%u", line);
				sv = *hv_fetch((HV*)SvRV(sv), text, len, 1);

				sv_setuv(sv, count);
				break;
			}

			case 'P':
			{
				unsigned int pid  = read_int();
				unsigned int ppid = read_int();
				int len = my_snprintf(text, sizeof(text), "%d", pid);
				hv_store(live_pids_hv, text, len, newSVuv(ppid), 0);
				if (trace_level)
					warn("Start of profile data for pid %s (ppid %d, %d pids live)\n",
						text, ppid, HvKEYS(live_pids_hv));
				break;
			}

			case 'p':
			{
				unsigned int pid = read_int();
				int len = my_snprintf(text, sizeof(text), "%d", pid);
				if (!hv_delete(live_pids_hv, text, len, 0))
					warn("Inconsistent pids in profile data (pid %d not introduced)", 
								pid);
				if (trace_level)
					warn("End of profile data for pid %s, %d remaining\n", text, 
								HvKEYS(live_pids_hv));
				break;
			}

			case ':':
			{
				char *value, *end;
				SV *value_sv;
				if (NULL == fgets(text, sizeof(text), in))
					croak("Profile format error reading attribute"); /* probably EOF */
				if ((NULL == (value = strchr(text, '=')))
				||  (NULL == (end   = strchr(text, '\n')))
				) {
					warn("attribute malformed '%s'\n", text);
					continue;
				}
				*value++ = '\0';
				value_sv = newSVpvn(value, end-value);
				hv_store(attr_hv, text, strlen(text), value_sv, 0);
				if (trace_level >= 2)
				    warn(": %s = '%s'\n", text, SvPV_nolen(value_sv)); /* includes \n */
				if ('t' == *text && strEQ(text, "ticks_per_sec"))
					ticks_per_sec = SvUV(value_sv);
				break;
			}

			case '#':
				if (NULL == fgets(text, sizeof(text), in))
					croak("Profile format error reading comment"); /* probably EOF */
				if (trace_level >= 2)
				    warn("# %s", text); /* includes \n */
				break;

			default:
				croak("File format error: token %d ('%c'), line %lu", c, c, input_line);
		}
	}

	if (EOF == c && HvKEYS(live_pids_hv)) {
		warn("profile data possibly truncated, no terminator for %d pids", 
					HvKEYS(live_pids_hv));
	}
	sv_free((SV*)live_pids_hv);

	profile_hv = newHV();
	hv_stores(profile_hv, "attribute",      newRV_noinc((SV*)attr_hv));
	hv_stores(profile_hv, "fid_filename",   newRV_noinc((SV*)fid_filename_av));
	hv_stores(profile_hv, "fid_line_time",  newRV_noinc((SV*)fid_line_time_av)); 
	if (fid_block_time_av)
		hv_stores(profile_hv, "fid_block_time", newRV_noinc((SV*)fid_block_time_av)); 
	if (fid_sub_time_av)
		hv_stores(profile_hv, "fid_sub_time",   newRV_noinc((SV*)fid_sub_time_av)); 
	if (sub_fid_lines_hv)
		hv_stores(profile_hv, "sub_fid_line",   newRV_noinc((SV*)sub_fid_lines_hv)); 
	if (sub_callers_hv)
		hv_stores(profile_hv, "sub_caller",     newRV_noinc((SV*)sub_callers_hv)); 
	return profile_hv;
}

/***********************************
 * Perl XS Code Below Here         *
 ***********************************/

MODULE = Devel::NYTProf		PACKAGE = Devel::NYTProf		
PROTOTYPES: DISABLE

MODULE = Devel::NYTProf		PACKAGE = DB
PROTOTYPES: DISABLE 

void
DB(...)
	CODE:
		PERL_UNUSED_VAR(items);
		if (use_db_sub)
			DB(aTHX);
	  else if (1||trace_level)
			warn("DB called needlessly");

void
set_option(const char *opt, const char *value)

int
init_profiler()
	C_ARGS:
	aTHX

int
enable_profile()
	C_ARGS:
	aTHX

int
disable_profile()
	C_ARGS:
	aTHX

void
_finish(...)
	PPCODE:
	is_finishing = 1;
	if (trace_level)
		warn("_finish (last_pid %d, getpid %d)\n", last_pid, getpid());
	DB(aTHX); /* write data for final statement */
	disable_profile(aTHX);
	if (out) {
		write_sub_line_ranges(aTHX_ 0);
		write_sub_callers(aTHX);
		/* mark end of profile data for last_pid pid
		 * (which is the pid that relates to the out filehandle)
		 */
		END_OUTPUT_PID(last_pid);
		if (-1 == fclose(out))
			warn("Error closing profile data file: %s", strerror(errno));
		out = NULL;
	}


MODULE = Devel::NYTProf		PACKAGE = Devel::NYTProf::Data
PROTOTYPES: DISABLE 

HV*
load_profile_data_from_file(file=NULL)
	char *file;
	CODE:

	if (trace_level)
		warn("reading profile data from file %s\n", file);
	in = fopen(file, "rb");
	if (in == NULL) {
		croak("Failed to open input '%s': %s", file, strerror(errno));
	}
	RETVAL = load_profile_data_from_stream();
	fclose(in);

	OUTPUT:
	RETVAL

