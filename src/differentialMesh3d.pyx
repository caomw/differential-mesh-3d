# -*- coding: utf-8 -*-
# cython: profile=True

from __future__ import division

cimport cython
cimport mesh3d

from zonemap3d cimport Zonemap3d

from cython.parallel import parallel, prange

from libc.math cimport sqrt
from libc.math cimport cos
from libc.math cimport sin
from libc.math cimport fabs

from helpers cimport double_array_init
from helpers cimport long_array_init

import numpy as np
cimport numpy as np


cdef class DifferentialMesh3d(mesh3d.Mesh3d):

  def __init__(self, long nmax, double zonewidth, double nearl, double farl, long procs):

    mesh3d.Mesh3d.__init__(self, nmax, zonewidth, procs)

    """
    - nearl is the closest comfortable distance between two vertices.

    - farl is the distance beyond which disconnected vertices will ignore
    each other
    """

    self.nearl = nearl

    self.farl = farl

    print('nearl: {:f}'.format(nearl))
    print('farl: {:f}'.format(farl))

    return

  def __cinit__(self, long nmax, *arg, **args):

    self.DX = <double *>malloc(nmax*sizeof(double))
    self.DY = <double *>malloc(nmax*sizeof(double))
    self.DZ = <double *>malloc(nmax*sizeof(double))
    self.DI = <double *>malloc(nmax*sizeof(double))

    return

  def __dealloc__(self):

    free(self.DX)
    free(self.DY)
    free(self.DZ)
    free(self.DI)

    return

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef long __smooth_intensity(
    self,
    long v1,
    double alpha,
    double *old,
    double *new,
    long *vertices,
    long num
  ) nogil:

    cdef double intens = old[v1]

    for k in xrange(num):

      intens = intens + alpha*old[vertices[k]]
      #new[v1] += ((b-a)*alpha + a*(1.0-alpha))/(1.0-alpha)

    new[v1] = intens/(1.0+<double>(num*alpha))

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef long __reject(
    self,
    long v,
    double *diffx,
    double *diffy,
    double *diffz,
    double stp,
    long *vertices,
    double *dst,
    long num,
    long *connected,
    long cnum
  ) nogil:

    cdef long k
    cdef long i
    cdef long k4
    cdef long neigh

    cdef double dx
    cdef double dy
    cdef double dz
    cdef double nrm
    cdef double s

    cdef long cont

    cdef double resx = 0.0
    cdef double resy = 0.0
    cdef double resz = 0.0

    for k in range(num):

      neigh = vertices[k]

      if neigh == v:
        continue

      cont = 1

      for i in xrange(cnum):
        if neigh == connected[i]:
          cont = -1
          break

      if cont<0:
        continue

      k4 = k*4
      nrm = dst[k4+3]

      if nrm>self.farl or nrm<=1e-9:
        continue

      dx = dst[k4]
      dy = dst[k4+1]
      dz = dst[k4+2]

      s = self.farl/nrm-1.0

      #if nrm<self.nearl:
        #s *= 2.0

      resx += dx*s
      resy += dy*s
      resz += dz*s

    diffx[v] += resx*stp
    diffy[v] += resy*stp
    diffz[v] += resz*stp

    return num

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef long __attract(
    self, long v1,
    double *diffx,
    double *diffy,
    double *diffz,
    double stp,
    long *vertices,
    long num
  ) nogil:

    cdef long v2
    cdef long k

    cdef double dx
    cdef double dy
    cdef double dz
    cdef double nrm

    cdef double s

    for k in xrange(num):

      v2 = vertices[k]

      dx = self.X[v2]-self.X[v1]
      dy = self.Y[v2]-self.Y[v1]
      dz = self.Z[v2]-self.Z[v1]
      nrm = sqrt(dx*dx+dy*dy+dz*dz)

      if nrm<1e-9:
        continue

      s = stp/nrm

      if nrm>self.nearl:

        ### attract
        diffx[v1] += dx*s
        diffy[v1] += dy*s
        diffz[v1] += dz*s

    return 1

  #@cython.wraparound(False)
  #@cython.boundscheck(False)
  #@cython.nonecheck(False)
  #@cython.cdivision(True)
  #cdef long __attract(
    #self, long v1,
    #double *diffx,
    #double *diffy,
    #double *diffz,
    #double stp,
    #long *vertices,
    #long num
  #) nogil:

    #cdef long v2
    #cdef long k

    #cdef double midx = 0.0
    #cdef double midy = 0.0
    #cdef double midz = 0.0

    #for k in xrange(num):

      #v2 = vertices[k]
      #midx += self.X[v2]
      #midy += self.Y[v2]
      #midz += self.Z[v2]

    #midx = midx/<double>(num) - self.X[v1]
    #midy = midy/<double>(num) - self.Y[v1]
    #midz = midz/<double>(num) - self.Z[v1]

    #cdef double nrm = sqrt(midx*midx+midy*midy+midz*midz)

    #if nrm<1e-9:

      #return -1

    #cdef double s = stp/nrm

    #diffx[v1] += midx*s
    #diffy[v1] += midy*s
    #diffz[v1] += midz*s

    #return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef long __unfold(
    self,
    long v1,
    double *diffx,
    double *diffy,
    double *diffz,
    double stp,
    long *vertices,
    long num
  ) nogil:

    cdef long v2
    cdef long first
    cdef long last
    cdef long k

    cdef double crossx
    cdef double crossy
    cdef double crossz

    cdef double v1x
    cdef double v1y
    cdef double v1z
    cdef double v2x
    cdef double v2y
    cdef double v2z

    cdef double ax
    cdef double ay
    cdef double az

    cdef double bx
    cdef double by
    cdef double bz

    cdef double cx
    cdef double cy
    cdef double cz

    cdef double nrm
    cdef double nrmc
    cdef double s

    cdef double resx = 0.0
    cdef double resy = 0.0
    cdef double resz = 0.0

    for k in xrange(num):

      he1 = vertices[k]

      if self.__is_surface_edge(he1)>0:
        continue

      first = self.HE[he1].first
      last = self.HE[he1].last

      v2 = self.HE[self.HE[self.HE[k].twin].next].last

      v1x = self.X[v1]
      v1y = self.Y[v1]
      v1z = self.Z[v1]

      v2x = self.X[v2]
      v2y = self.Y[v2]
      v2z = self.Z[v2]

      ax = self.X[first]-v1x
      ay = self.Y[first]-v1y
      az = self.Z[first]-v1z

      bx = self.X[last]-v1x
      by = self.Y[last]-v1y
      bz = self.Z[last]-v1z

      cx = v1x-v2x
      cy = v1y-v2y
      cz = v1z-v2z

      crossx = ay*bz-by*az
      crossy = -(ax*bz-az*bx)
      crossz = ax*by-ay*bx

      if crossx*cx + crossy*cy + crossz*cz<0.:
        ## flip
        crossx = by*az-ay*bz
        crossy = -(bx*az-bz*ax)
        crossz = bx*ay-by*ax

      nrm = sqrt(crossx*crossx+crossy*crossy+crossz*crossz)
      nrmc = sqrt(cx*cx+cy*cy+cz*cz)

      if nrm<1e-9 or nrmc<1e-9:
        continue

      crossx /= nrm
      crossy /= nrm
      crossz /= nrm

      # s = (1.0-fabs(crossx*cx/nrmc+crossy*cy/nrmc+crossz*cz/nrmc))*stp
      s = stp

      ## reject
      resx += crossx*s
      resy += crossy*s
      resz += crossz*s

    diffx[v1] += resx
    diffy[v1] += resy
    diffz[v1] += resz

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef long __triangle(
    self,
    long v1,
    double *diffx,
    double *diffy,
    double *diffz,
    double stp,
    long *vertices,
    long num
  ) nogil:

    cdef long k

    for k in xrange(num):

      self.__edge_vertex_force(v1, diffx, diffy, diffz, vertices[k], stp)

    return num

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cdef long __edge_vertex_force(
    self,
    long v1,
    double *diffx,
    double *diffy,
    double *diffz,
    long he1,
    double stp
  ) nogil:

    cdef long henum = self.henum
    cdef double nearl = self.nearl

    cdef long a = self.HE[he1].first
    cdef long b = self.HE[he1].last

    cdef double x = (self.X[b]+self.X[a])*0.5
    cdef double y = (self.Y[b]+self.Y[a])*0.5
    cdef double z = (self.Z[b]+self.Z[a])*0.5

    cdef double dx = self.X[v1]-x
    cdef double dy = self.Y[v1]-y
    cdef double dz = self.Z[v1]-z

    cdef double nrm = sqrt(dx*dx+dy*dy+dz*dz)

    if nrm<=0:

      return -1

    if nrm>0.5*sqrt(3.0)*nearl:

      #pass
      diffx[v1] += -dx/nrm*stp
      diffy[v1] += -dy/nrm*stp
      diffz[v1] += -dz/nrm*stp

    else:

      diffx[v1] += dx/nrm*stp
      diffy[v1] += dy/nrm*stp
      diffz[v1] += dz/nrm*stp

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  @cython.cdivision(True)
  cpdef long optimize_position(
    self,
    double reject_stp,
    double attract_stp,
    double unfold_stp,
    double triangle_stp,
    double diminish,
    double alpha,
    long scale_intensity
  ):

    cdef long v
    cdef long i

    cdef double x
    cdef double y
    cdef double z
    cdef double dx
    cdef double dy
    cdef double dz
    cdef double nrm
    cdef double stp_limit = self.nearl*0.3

    cdef long *vertices
    cdef long *connected
    cdef long num
    cdef long cnum
    cdef double *dst

    cdef long asize = self.zonemap.__get_max_sphere_count()

    with nogil, parallel(num_threads=self.procs):

      vertices = <long *>malloc(asize*sizeof(long))
      connected = <long *>malloc(asize*sizeof(long))
      dst = <double *>malloc(asize*sizeof(double)*4)

      for v in prange(self.vnum, schedule='guided'):

        self.DX[v] = 0.0
        self.DY[v] = 0.0
        self.DZ[v] = 0.0

        # sphere/connected
        cnum = self.__get_connected_vertices(v, connected)
        num = self.zonemap.__sphere_vertices_dst(
          self.X[v],
          self.Y[v],
          self.Z[v],
          self.farl,
          vertices,
          dst
        )
        self.__reject(
          v,
          self.DX,
          self.DY,
          self.DZ,
          reject_stp,
          vertices,
          dst,
          num,
          connected,
          cnum
        )

        # connected
        self.__attract(
          v,
          self.DX,
          self.DY,
          self.DZ,
          attract_stp,
          connected,
          cnum
        )
        self.__smooth_intensity(
          v,
          alpha,
          self.I,
          self.DI,
          connected,
          cnum
        )

        # opposite
        # num = self.__get_opposite_edges(v, vertices)
        # self.__unfold(
        #   v,
        #   self.DX,
        #   self.DY,
        #   self.DZ,
        #   unfold_stp,
        #   vertices,
        #   num
        # )
        # self.__triangle(
        #   v,
        #   self.DX,
        #   self.DY,
        #   self.DZ,
        #   triangle_stp,
        #   vertices,
        #   num
        # )

      free(vertices)
      free(connected)
      free(dst)

      for v in prange(self.vnum, schedule='static'):

        dx = self.DX[v]
        dy = self.DY[v]
        dz = self.DZ[v]

        nrm = sqrt(dx*dx+dy*dy+dz*dz)

        if nrm>stp_limit:
          dx = dx / nrm * stp_limit
          dy = dy / nrm * stp_limit
          dz = dz / nrm * stp_limit

        if scale_intensity>0:
          x = self.X[v] + self.I[v]*dx
          y = self.Y[v] + self.I[v]*dy
          z = self.Z[v] + self.I[v]*dz
        else:
          x = self.X[v] + dx
          y = self.Y[v] + dy
          z = self.Z[v] + dz

        self.X[v] = x
        self.Y[v] = y
        self.Z[v] = z
        self.I[v] = self.DI[v]*diminish

    with nogil:
      for v in xrange(self.vnum):
        self.zonemap.__update_v(v)

    return 1

  @cython.wraparound(False)
  @cython.boundscheck(False)
  @cython.nonecheck(False)
  cpdef long position_noise(self, np.ndarray[double, mode="c",ndim=2] a, long scale_intensity):

    cdef long v
    cdef double intensity = 1

    for v in xrange(self.vnum):

      if scale_intensity>0:
        intensity = self.I[v]

      self.X[v] += a[v,0]*intensity
      self.Y[v] += a[v,1]*intensity
      self.Z[v] += a[v,2]*intensity

    return 1

