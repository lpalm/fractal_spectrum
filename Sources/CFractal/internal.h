// Definitions shared by the C sources but hidden from Swift.
#ifndef CFRACTAL_INTERNAL_H
#define CFRACTAL_INTERNAL_H
#include <mpfr.h>
#include "CFractal.h"

struct FSHP {
    mpfr_t value;
};

#endif
