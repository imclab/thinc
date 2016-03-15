from cymem.cymem cimport Pool
from preshed.maps cimport map_init as Map_init
from preshed.maps cimport map_set as Map_set
from preshed.maps cimport map_get as Map_get
from preshed.maps cimport map_iter as Map_iter
from preshed.maps cimport key_t

from ..typedefs cimport weight_t, atom_t, feat_t
from ..typedefs cimport len_t, idx_t
from ..linalg cimport MatMat, MatVec, VecVec, Vec
from .. cimport prng
from ..structs cimport MapC
from ..structs cimport NeuralNetC
from ..structs cimport ExampleC
from ..structs cimport FeatureC
from ..structs cimport EmbedC
from ..structs cimport ConstantsC
from ..structs cimport do_update_t

from ..extra.eg cimport Example

from .initializers cimport he_normal_initializer, he_uniform_initializer

from libc.string cimport memcpy
from libc.math cimport isnan, sqrt

import random
import numpy


cdef class Embedding:
    cdef Pool mem
    cdef EmbedC* c

    @staticmethod
    cdef inline void init(EmbedC* self, Pool mem, vector_widths, features) except *: 
        assert max(features) < len(vector_widths)
        # Create tables, which may be shared between different features
        # e.g., we might have a feature for this word, and a feature for next
        # word. These occupy different parts of the input vector, but draw
        # from the same embedding table.
        self.nr = len(features)
        uniq_weights = <MapC*>mem.alloc(len(vector_widths), sizeof(MapC))
        uniq_gradients = <MapC*>mem.alloc(len(vector_widths), sizeof(MapC))
        for i, width in enumerate(vector_widths):
            Map_init(mem, &uniq_weights[i], 8)
            Map_init(mem, &uniq_gradients[i], 8)
        self.offsets = <idx_t*>mem.alloc(len(features), sizeof(len_t))
        self.lengths = <len_t*>mem.alloc(len(features), sizeof(len_t))
        self.weights = <MapC**>mem.alloc(len(features), sizeof(void*))
        self.gradients = <MapC**>mem.alloc(len(features), sizeof(void*))
        offset = 0
        for i, table_id in enumerate(features):
            self.weights[i] = &uniq_weights[table_id]
            self.gradients[i] = &uniq_gradients[table_id]
            self.lengths[i] = vector_widths[table_id]
            self.offsets[i] = offset
            offset += vector_widths[table_id]

    @staticmethod
    cdef inline void set_input(weight_t* out,
            const FeatureC* features, len_t nr_feat, const EmbedC* embed) nogil:
        for feat in features[:nr_feat]:
            if feat.value == 0:
                continue
            emb = <const weight_t*>Map_get(embed.weights[feat.i], feat.key)
            if emb is not NULL:
                VecVec.add_i(&out[embed.offsets[feat.i]], 
                    emb, feat.value, embed.lengths[feat.i])

    @staticmethod
    cdef inline void insert_missing(Pool mem, EmbedC* embed,
            const FeatureC* features, len_t nr_feat) except *:
        cdef weight_t* grad
        for feat in features[:nr_feat]:
            if feat.i >= embed.nr or feat.value == 0:
                continue
            emb = <weight_t*>Map_get(embed.weights[feat.i], feat.key)
            if emb is NULL:
                emb = <weight_t*>mem.alloc(embed.lengths[feat.i], sizeof(emb[0]))
                he_uniform_initializer(emb, -0.5, 0.5, embed.lengths[feat.i])
                Map_set(mem, embed.weights[feat.i],
                    feat.key, emb)
                grad = <weight_t*>mem.alloc(embed.lengths[feat.i], sizeof(grad[0]))
                Map_set(mem, embed.gradients[feat.i],
                    feat.key, grad)
    
    @staticmethod
    cdef inline void fine_tune(EmbedC* layer,
            const weight_t* delta, int nr_delta, const FeatureC* features, int nr_feat) nogil:
        cdef size_t last_update
        for feat in features[:nr_feat]:
            if feat.value == 0:
                continue
            gradient = <weight_t*>Map_get(layer.gradients[feat.i], feat.key)
            # None of these should ever be null
            if gradient is not NULL:
                VecVec.add_i(gradient,
                    &delta[layer.offsets[feat.i]], feat.value, layer.lengths[feat.i])

    @staticmethod
    cdef inline void update_all(EmbedC* layer,
            const ConstantsC* hp, do_update_t do_update) nogil:
        cdef key_t key
        cdef void* value
        cdef int i, j
        for i in range(layer.nr):
            j = 0
            while Map_iter(layer.weights[i], &j, &key, &value):
                emb = <weight_t*>value
                grad = <weight_t*>Map_get(layer.gradients[i], key)
                if emb is not NULL and grad is not NULL:
                    do_update(emb, grad,
                        layer.lengths[i], hp)