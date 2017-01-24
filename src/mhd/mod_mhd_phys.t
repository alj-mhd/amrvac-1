! TODO: GLM (to module?)
! TODO: B0field (inside here / module?)
! TODO: fourthorder

!> Magneto-hydrodynamics module
module mod_mhd_phys
  use mod_physic

  implicit none
  private

  !> Whether an energy equation is used
  logical, public, protected              :: mhd_energy = .true.

  !> Whether thermal conduction is used
  logical, public, protected              :: mhd_thermal_conduction = .false.

  !> Whether Hall-MHD is used
  logical, public, protected              :: mhd_Hall = .false.

  !> Number of tracer species
  integer, public, protected              :: mhd_n_tracer = 0

  !> Index of the density (in the w array)
  integer, public, parameter              :: rho_ = 1

  !> Indices of the momentum density
  integer, allocatable, public, protected :: mom(:)

  !> Indices of the magnetic field
  integer, allocatable, public, protected :: mag(:)

  !> Indices of the tracers
  integer, allocatable, public, protected :: tracer(:)

  !> Index of the energy density (-1 if not present)
  integer, public, protected              :: e_

  !> Index of the gas pressure (-1 if not present) should equal e_
  integer, public, protected              :: p_

  !> The number of flux variables in this module
  integer, public, protected              :: mhd_nwflux

  !> The adiabatic index
  double precision, public, protected     :: mhd_gamma = 5/3.0d0

  !> The adiabatic constant
  double precision, public, protected     :: mhd_adiab = 1.0d0

  !> The MHD resistivity
  double precision, public, protected     :: mhd_eta = 0.0d0

  !> The MHD hyper-resistivity
  double precision, public, protected     :: mhd_eta_hyper = 0.0d0

  !> TODO: what is this?
  double precision, public, protected     :: mhd_etah = 0.0d0

  !> The smallest allowed energy
  double precision, protected             :: smalle

  !> The smallest allowed density
  double precision, protected             :: minrho

  !> The smallest allowed pressure
  double precision, protected             :: minp

contains

  {#IFDEF ENERGY
  INTEGER,PARAMETER:: nwwave=8
  }{#IFNDEF ENERGY
  INTEGER,PARAMETER:: nwwave=7
  }

  subroutine mhd_check_params
    use mod_global_parameters

    minrho = max(0.0d0, smallrho)

    if (.not. mhd_energy) then
       if (mhd_gamma <= 0.0d0) call mpistop ("Error: mhd_gamma <= 0")
       if (mhd_adiab < 0.0d0) call mpistop ("Error: mhd_adiab < 0")
       minp   = mhd_adiab*minrho**mhd_gamma
    else
       if (mhd_gamma <= 0.0d0 .or. mhd_gamma == 1.0d0) &
            call mpistop ("Error: mhd_gamma <= 0 or mhd_gamma == 1")
       minp   = max(0.0d0, smallp)
       smalle = minp/(mhd_gamma - 1.0d0)
    end if

  end subroutine mhd_check_params

  subroutine mhd_phys_init()
    use mod_global_parameters
    use mod_thermal_conduction

    integer :: itr, idir

    call mhd_params_read(par_files)

    physics_type = "mhd"

    ! Determine flux variables
    nwflux = 1                  ! rho (density)

    allocate(mom(ndir))
    do idir = 1, ndir
       nwflux    = nwflux + 1
       mom(idir) = nwflux       ! momentum density
    end do

    ! Set index of energy variable
    if (mhd_energy) then
       nwflux = nwflux + 1
       e_     = nwflux          ! energy density
       p_     = nwflux          ! gas pressure
    else
       e_ = -1
       p_ = -1
    end if

    allocate(mag(ndir))
    do idir = 1, ndir
       nwflux    = nwflux + 1
       mag(idir) = nwflux       ! magnetic field
    end do

    if (mhd_glm) then
       nwflux = nwflux + 1
       psi_   = nwflux
    else
       psi_ = -1
    end if

    allocate(tracer(mhd_n_tracer))

    ! Set starting index of tracers
    do itr = 1, mhd_n_tracer
       nwflux = nwflux + 1
       tracer(itr) = nwflux     ! tracers
    end do

    mhd_nwflux = nwflux

    nwaux   = 0
    nwextra = 0
    nw      = nwflux + nwaux + nwextra
    nflag_  = nw + 1

    nvector      = 2 ! No. vector vars
    allocate(iw_vector(nvector))
    iw_vector(1) = mom(1) - 1   ! TODO: why like this?
    iw_vector(2) = mag(1) - 1   ! TODO: why like this?

    phys_get_v           => mhd_get_v
    phys_get_dt          => mhd_get_dt
    phys_get_cmax        => mhd_get_cmax
    phys_get_flux        => mhd_get_flux
    phys_add_source_geom => mhd_add_source_geom
    phys_to_conserved    => mhd_to_conserved
    phys_to_primitive    => mhd_to_primitive
    phys_check_params    => mhd_check_params
    phys_check_w         => mhd_check_w

    ! initialize thermal conduction module
    if (mhd_thermal_conduction) then
       tc_gamma               =  mhd_gamma
       phys_get_heatconduct   => mhd_get_heatconduct
       phys_getdt_heatconduct => mhd_getdt_heatconduct
       call thermal_conduction_init()
    end if

    if (mhd_glm) then
       ! Solve the Riemann problem for the linear 2x2 system for normal
       ! B-field and GLM_Psi according to Dedner 2002:
       phys_modify_interface => glmSolve
    end if

    ! For Hall, we need one more reconstructed layer since currents are computed
    ! in getflux: assuming one additional ghost layer (two for FOURTHORDER) was
    ! added in dixB.
    if (mhd_hall) then
       if (mhd_4th_order) then
          phys_wider_stencil = 2
       else
          phys_wider_stencil = 1
       end if
    end if

  end subroutine mhd_phys_init

  subroutine mhd_check_w(checkprimitive,ixI^L,ixO^L,w,flag)

    use mod_global_parameters

    logical :: checkprimitive
    integer, intent(in) :: ixI^L, ixO^L
    double precision :: w(ixI^S,nw)
    logical :: flag(ixI^S)

    double precision :: tmp1(ixI^S)
    !-----------------------------------------------------------------------------
    flag(ixI^S)=.true.

    if (mhd_energy) then
       if (checkprimitive)then
          tmp1(ixO^S)=w(ixO^S,p_)
       else
          ! First calculate kinetic energy*2=m**2/rho
          tmp1(ixO^S)=( ^C&w(ixO^S,m^C_)**2+ )/w(ixO^S,rho_)
          ! Add magnetic energy*2=b**2
          tmp1(ixO^S)=tmp1(ixO^S)+ ^C&w(ixO^S,b^C_)**2+
          ! Calculate pressure=(gamma-1)*(e-0.5*(2ek+2eb))
          tmp1(ixO^S)=(mhd_gamma-one)*(w(ixO^S,e_)-half*tmp1(ixO^S))
       end if

       flag(ixO^S)=(tmp1(ixO^S)>=minp .and. w(ixO^S,rho_)>=minrho)
    else
       flag(ixO^S)=(w(ixO^S,rho_)>=minrho)
    end if
  end subroutine mhd_check_w

  !> Transform primitive variables into conservative ones
  subroutine mhd_to_conserved(ixI^L,ixO^L,w,x,patchw)
    use mod_global_parameters
    integer, intent(in)             :: ixI^L, ixO^L
    double precision, intent(inout) :: w(ixI^S, nw)
    double precision, intent(in)    :: x(ixI^S, 1:ndim)
    double precision                :: invgam
    integer                         :: idir, itr

    ! Convert velocity to momentum
    do idir = 1, ndir
       w(ixO^S, mom(idir)) = w(ixO^S, rho_) * w(ixO^S, mom(idir))
    end do

    if (mhd_energy) then
       invgam=1.d0/(mhd_gamma-one)
       ! Calculate total energy from pressure, kinetic and magnetic energy
       w(ixO^S,e_)=w(ixO^S,p_)*invgam + &
            mhd_kin_en(w, ixI^L, ixO^L) + mhd_mag_en(w, ixI^L, ixO^L)
    end if

    do itr = 1, mhd_n_tracer
       w(ixO^S, tracer(itr)) = w(ixO^S, rho_) * w(ixO^S, tracer(itr))
    end do

    ! if(fixsmall) call smallvalues(w,x,ixI^L,ixO^L,"conserve")
  end subroutine mhd_to_conserved

  !> Transform conservative variables into primitive ones
  subroutine mhd_to_primitive(ixI^L,ixO^L,w,x)
    use mod_global_parameters
    integer, intent(in)             :: ixI^L, ixO^L
    double precision, intent(inout) :: w(ixI^S, nw)
    double precision, intent(in)    :: x(ixI^S, 1:ndim)
    integer                         :: itr, idir

    if (mhd_energy) then
       ! Calculate pressure = (gamma-1) * (e-0.5*(2ek+2eb))
       w(ixO^S, e_) = (mhd_gamma - 1.0d0) * (w(ixO^S, e_) &
            - mhd_kin_en(w, ixI^L, ixO^L) &
            - mhd_mag_en(w, ixI^L, ixO^L))
    end if

    ! Convert momentum to velocity
    do idir = 1, ndir
       w(ixO^S, mom(idir)) = w(ixO^S, mom(idir)) * mhd_inv_rho(w, ixI^L, ixO^L)
    end do

    do itr = 1, mhd_n_tracer
       w(ixO^S, tracer(itr)) = w(ixO^S, tracer(itr)) * mhd_inv_rho(w, ixI^L, ixO^L)
    end do

    ! call handle_small_values(.true., w, x, ixI^L, ixO^L)
  end subroutine mhd_to_primitive

  subroutine e_to_rhos(ixI^L,ixO^L,w,x)
    use mod_global_parameters
    integer, intent(in)             :: ixI^L, ixO^L
    double precision,intent(inout)  :: w(ixI^S,nw)
    double precision, intent(in)    :: x(ixI^S,1:ndim)

    if (mhd_energy) then
       w(ixO^S, e_) = (mhd_gamma - 1.0d0) * w(ixO^S, rho_)**(1.0d0 - mhd_gamma) * &
            (w(ixO^S, e_) - mhd_kin_en(w, ixI^L, ixO^L) &
            - mhd_mom_en(w, ixI^L, ixO^L)) &
            else
       call mpistop("e_to_rhos can not be used with eos=iso !")
    end if
  end subroutine e_to_rhos

  subroutine rhos_to_e(ixI^L,ixO^L,w,x)
    use mod_global_parameters
    integer, intent(in) :: ixI^L, ixO^L
    double precision :: w(ixI^S,nw)
    double precision, intent(in)    :: x(ixI^S,1:ndim)

    if (mhd_energy) then
       w(ixO^S, e_) = w(ixO^S, rho_)**(mhd_gamma - 1.0d0) * w(ixO^S, e_) &
            / (mhd_gamma - 1.0d0) + mhd_kin_en(w, ixI^L, ixO^L) + &
            mhd_mom_en(w, ixI^L, ixO^L) + &
            else
       call mpistop("rhos_to_e can not be used with eos=iso !")
    end if
  end subroutine rhos_to_e

  !> Get internal energy
  subroutine internalenergy(ixI^L,ixO^L,w,x,ie)
    use mod_global_parameters
    integer, intent(in)             :: ixI^L, ixO^L
    double precision, intent(in)    :: w(ixI^S,nw)
    double precision, intent(in)    :: x(ixI^S,1:ndim)
    double precision                :: ie(ixI^S)

    if (mhd_energy) then
       ie(ixO^S)=( ^C&w(ixO^S,m^C_)**2+ )/w(ixO^S,rho_)+ ^C&w(ixO^S,b^C_)**2+
       ! internal energy=e-0.5*(2ek+2eb)
       ie(ixO^S)=w(ixO^S,e_)-half*ie(ixO^S)
    else
       call mpistop("internalenergy can not be used with eos=iso !")
    end if

  end subroutine internalenergy

  !> Calculate v_idim=m_idim/rho within ixO^L
  subroutine mhd_get_v(w,x,ixI^L,ixO^L,idims,v)
    use mod_global_parameters

    integer, intent(in)           :: ixI^L, ixO^L, idims
    double precision, intent(in)  :: w(ixI^S,nw)
    double precision, intent(in)  :: x(ixI^S,1:ndim)
    double precision, intent(out) :: v(ixI^S)

    v(ixO^S)=w(ixO^S,m0_+idims)/w(ixO^S,rho_)

  end subroutine mhd_get_v

  !> Calculate cmax_idim=csound+abs(v_idim) within ixO^L
  subroutine mhd_get_cmax(new_cmax,w,x,ixI^L,ixO^L,idims,cmax,cmin,needcmin)
    use mod_global_parameters

    logical                      :: new_cmax,needcmin
    integer, intent(in)          :: ixI^L, ixO^L, idims
    double precision             :: w(ixI^S,nw), cmax(ixI^S), cmin(ixI^S)
    double precision, intent(in) :: x(ixI^S,1:ndim)

    double precision :: csound2(ixI^S), cfast2(ixI^S), AvMinCs2(ixI^S), tmp(ixI^S)
    double precision :: bmag2(ixI^S), kmax

    !Direction independent part of getcmax:
    call getcsound2(w,x,ixI^L,ixO^L,csound2)

    if (B0field) then
       cfast2(ixO^S)=( ^C&(w(ixO^S,b^C_)+myB0%w(ixO^S,^C))**2+ ) &
            /w(ixO^S,rho_)+csound2(ixO^S)
       AvMinCs2(ixO^S)=cfast2(ixO^S)**2-4.0d0*csound2(ixO^S)&
            *((myB0%w(ixO^S,idims)+w(ixO^S,b0_+idims))**2) &
            /w(ixO^S,rho_)
    else
       cfast2(ixO^S)=( ^C&w(ixO^S,b^C_)**2+ )/w(ixO^S,rho_)+csound2(ixO^S)
       AvMinCs2(ixO^S)=cfast2(ixO^S)**2-4.0d0*csound2(ixO^S)&
            *((w(ixO^S,b0_+idims))**2)/w(ixO^S,rho_)
    end if

    where(AvMinCs2(ixO^S)<zero)
       AvMinCs2(ixO^S)=zero
    end where

    AvMinCs2(ixO^S)=dsqrt(AvMinCs2(ixO^S))

    if (.not. MHD_Hall) then
       tmp(ixO^S) = dsqrt(half*(cfast2(ixO^S)+AvMinCs2(ixO^S)))
    else
       if (.not. B0field) then
          bmag2(ixO^S)={^C& w(ixO^S,b^C_)**2 +}
       else
          bmag2(ixO^S)={^C& (w(ixO^S,b^C_)+myB0%w(ixO^S,^C))**2 +}
       end if
       ! take the Hall velocity into account:
       ! most simple estimate, high k limit:
       ! largest wavenumber supported by grid: Nyquist (in practise can reduce by some factor)
       kmax = dpi/min({dxlevel(^D)},bigdouble)*half
       tmp(ixO^S) = max(dsqrt(half*(cfast2(ixO^S)+AvMinCs2(ixO^S))), &
            mhd_etah * sqrt(bmag2(ixO^S))/w(ixO^S,rho_)*kmax)
    end if

    if (needcmin)then
       cmax(ixO^S)=max(+tmp(ixO^S) &
            +(w(ixO^S,m0_+idims)/w(ixO^S,rho_)),zero)
       cmin(ixO^S)=min(-tmp(ixO^S) &
            +(w(ixO^S,m0_+idims)/w(ixO^S,rho_)),zero)
    else
       cmax(ixO^S)=tmp(ixO^S) &
            +dabs(w(ixO^S,m0_+idims)/w(ixO^S,rho_))
    end if

  end subroutine mhd_get_cmax

  !> Calculate thermal pressure=(gamma-1)*(e-0.5*m**2/rho-b**2/2) within ixO^L
  subroutine mhd_get_pthermal(w,x,ixI^L,ixO^L,p)
    use mod_global_parameters

    integer, intent(in)          :: ixI^L, ixO^L
    double precision             :: w(ixI^S,nw), p(ixI^S)
    double precision, intent(in) :: x(ixI^S,1:ndim)
    integer, dimension(ixI^S)    :: patchierror
    integer, dimension(ndim)     :: lowpindex

    if (mhd_energy) then
       ! Calculate pressure=(gamma-1)*(e-0.5*(2ek+2eb))
       p(ixO^S)=(mhd_gamma-one)*(w(ixO^S,e_)- &
            half*(({^C&w(ixO^S,m^C_)**2+})/w(ixO^S,rho_)&
            +{^C&w(ixO^S,b^C_)**2+}))
    else
       p(ixO^S)=mhd_adiab*w(ixO^S,rho_)**mhd_gamma
    end if
  end subroutine mhd_get_pthermal

  !> Calculate the square of the thermal sound speed csound2 within ixO^L
  !> from the primitive variables in w.
  !> csound2=gamma*p/rho
  subroutine getcsound2prim(w,x,ixI^L,ixO^L,csound2)
    use mod_global_parameters
    integer, intent(in)             :: ixO^L, ixI^L
    double precision, intent(in)    :: x(ixI^S,1:ndim)
    double precision, intent(in)    :: w(ixI^S,nw)
    double precision, intent(out)   :: csound2(ixI^S)

    if (mhd_energy) then
       csound2(ixO^S)=mhd_gamma*w(ixO^S,p_)/w(ixO^S,rho_)
    else
       csound2(ixO^S)=mhd_gamma*mhd_adiab*w(ixO^S,rho_)**(mhd_gamma-one)
    end if
  end subroutine getcsound2prim

  !> Calculate the square of the thermal sound speed csound2 within ixO^L.
  !> csound2=gamma*p/rho
  subroutine getcsound2(w,x,ixI^L,ixO^L,csound2)
    use mod_global_parameters
    integer, intent(in)             :: ixI^L, ixO^L
    double precision, intent(in)    :: w(ixI^S,nw)
    double precision, intent(in)    :: x(ixI^S,1:ndim)
    double precision, intent(out)   :: csound2(ixI^S)

    if (mhd_energy) then
       call getpthermal(w,x,ixI^L,ixO^L,csound2)
       csound2(ixO^S)=mhd_gamma*csound2(ixO^S)/w(ixO^S,rho_)
    else
       csound2(ixO^S)=mhd_gamma*mhd_adiab*w(ixO^S,rho_)**(mhd_gamma-one)
    end if
  end subroutine getcsound2

  ! Calculate total pressure within ixO^L including magnetic pressure
  ! p=(g-1)*e-0.5*(g-1)*m**2/rho+(1-0.5*g)*b**2
  subroutine getptotal(w,x,ixI^L,ixO^L,p)
    use mod_global_parameters

    integer, intent(in)             :: ixI^L, ixO^L
    double precision, intent(in)    :: w(ixI^S,nw)
    double precision, intent(in)    :: x(ixI^S,1:ndim)
    double precision, intent(out)   :: p(ixI^S)
    !.. local ..
    integer, dimension(ixI^S)       :: patchierror
    integer, dimension(ndim)       :: lowpindex

    ! if(fixsmall) call smallvalues(w,x,ixI^L,ixO^L,'getptotal')

    if (mhd_energy) then
       p(ixO^S)=(one-half*mhd_gamma)*( ^C&w(ixO^S,b^C_)**2+ )+(mhd_gamma-one)*&
            (w(ixO^S,e_)-half*(^C&w(ixO^S,m^C_)**2+)/w(ixO^S,rho_))
    else
       p(ixO^S)=mhd_adiab*w(ixO^S,rho_)**mhd_gamma+(^C&w(ixO^S,b^C_)**2+)*half
    end if

  end subroutine getptotal

  !> Calculate non-transport flux f_idim[iw] within ixO^L.
  subroutine mhd_get_flux(w,x,ixI^L,ixO^L,iw,idims,f,transport)
    use mod_global_parameters

    integer, intent(in)          :: ixI^L, ixO^L, iw, idims
    double precision, intent(in) :: w(ixI^S,nw)
    double precision, intent(in) :: x(ixI^S,1:ndim)
    double precision,intent(out) :: f(ixI^S)
    !.. local ..
    logical                      :: transport
    double precision             :: tmp(ixI^S), vh(ixI^S,1:3)
    integer                      :: idirmin, idir

    transport = .true.

    if (B0field) then
       if (iw==m0_+idims{#IFDEF ENERGY .or. iw==e_}) then
          tmp(ixO^S)={^C&myB0%w(ixO^S,^C)*w(ixO^S,b^C_)+}
       end if
    end if

    select case (iw)
    case (rho_)
       ! f_i[rho]=v_i*rho
       f(ixO^S)=zero

    case (tracer TODO)
       f(ixO^S)=zero

    case (mom TODO)
       ! f_i[m_k]=v_i*m_k-b_k*b_i [+ptotal if i==k]

       if (idims==^C) then
          call getptotal(w,x,ixI^L,ixO^L,f)
          f(ixO^S)=f(ixO^S)-w(ixO^S,b0_+idims)*w(ixO^S,b^C_)
          if (B0field) f(ixO^S)=f(ixO^S)+tmp(ixO^S)
       else
          f(ixO^S)= -w(ixO^S,b^C_)*w(ixO^S,b0_+idims)
       end if

       if (B0field) then
          f(ixO^S)=f(ixO^S)-myB0%w(ixO^S,idims)*w(ixO^S,b^C_) &
               -w(ixO^S,b0_+idims)*myB0%w(ixO^S,^C)
       end if

    case (e_)
       ! f_i[e]=v_i*e+(m_i*ptotal-b_i*(b_k*m_k))/rho
       call getptotal(w,x,ixI^L,ixO^L,f)
       f(ixO^S)=(w(ixO^S,m0_+idims)*f(ixO^S)- &
            w(ixO^S,b0_+idims)*( ^C&w(ixO^S,b^C_)*w(ixO^S,m^C_)+ ))/w(ixO^S,rho_)

       if (mhd_Hall) then
          ! f_i[e]= f_i[e] + vh_i*(b_k*b_k) - b_i*(vh_k*b_k)
          if (mhd_etah>zero) then
             call getvh(w,x,ixI^L,ixO^L,vh)
             f(ixO^S) = f(ixO^S) + vh(ixO^S,idims)*&
                  (^C&w(ixO^S,b^C_)*w(ixO^S,b^C_)+ )&
                  - w(ixO^S,b0_+idims) * (^C&vh(ixO^S,^C)*w(ixO^S,b^C_)+ )
             if (B0field) then
                f(ixO^S) = f(ixO^S) &
                     + vh(ixO^S,idims) * tmp(ixO^S) &
                     - (^C&vh(ixO^S,^C)*w(ixO^S,b^C_)+ ) * myB0%w(ixO^S,idims)
             end if
          end if
       end if

       if (B0field) then
          f(ixO^S)=f(ixO^S)+ tmp(ixO^S) &
               *w(ixO^S,m0_+idims)/w(ixO^S,rho_) &
               -( ^C&w(ixO^S,m^C_)*w(ixO^S,b^C_)+ )/w(ixO^S,rho_) &
               *myB0%w(ixO^S,idims)
       end if

    case (mag TODO)
       ! f_i[b_k]=v_i*b_k-m_k/rho*b_i
       if (idims==^C) then
          ! f_i[b_i] should be exactly 0, so we do not use the transport flux
          if (mhd_glm) then
             f(ixO^S)=w(ixO^S,psi_)
          else
             f(ixO^S)=zero
          end if
          transport=.false.
       else
          f(ixO^S)= -w(ixO^S,b0_+idims)*w(ixO^S,m^C_)/w(ixO^S,rho_)

          if (B0field) then
             f(ixO^S)=f(ixO^S) &
                  +w(ixO^S,m0_+idims)/w(ixO^S,rho_)*myB0%w(ixO^S,^C) &
                  -myB0%w(ixO^S,idims)*w(ixO^S,m^C_)/w(ixO^S,rho_)
          end if

          if (mhd_Hall) then
             ! f_i[b_k] = f_i[b_k] + vh_i*b_k - vh_k*b_i
             if (mhd_etah>zero) then
                call getvh(w,x,ixI^L,ixO^L,vh)
                if (B0field) then
                   f(ixO^S) = f(ixO^S) &
                        - vh(ixO^S,^C)*(w(ixO^S,b0_+idims)+myB0%w(ixO^S,idims)) &
                        + vh(ixO^S,idims)*(w(ixO^S,b^C_)+myB0%w(ixO^S,^C))
                else 
                   f(ixO^S) = f(ixO^S) &
                        - vh(ixO^S,^C)*w(ixO^S,b0_+idims) &
                        + vh(ixO^S,idims)*w(ixO^S,b^C_)
                end if
             end if
          end if

       end if

    case(psi_)
       ! TODO: only with GLM
       !f_i[psi]=Ch^2*b_{i}
       ! Eq. 24e and Eq. 38c Dedner et al 2002 JCP, 175, 645
       f(ixO^S)  = cmax_global**2*w(ixO^S,b0_+idims)
       transport = .false.
    case default
       call mpistop("Error in getflux: unknown flow variable!")
    end select

  end subroutine mhd_get_flux

  !> w[iws]=w[iws]+qdt*S[iws,wCT] where S is the source based on wCT within ixO
  subroutine mhd_add_source(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,qsourcesplit)
    use mod_global_parameters

    integer, intent(in)             :: ixI^L, ixO^L, iw^LIM
    double precision, intent(in)    :: qdt, qtC, qt
    double precision, intent(in)    :: wCT(ixI^S,1:nw), x(ixI^S,1:ndim)
    double precision, intent(inout) :: w(ixI^S,1:nw)
    logical, intent(in)             :: qsourcesplit
    !.. local ..
    double precision:: dx^D
    !-----------------------------------------------------------------------------

    dx^D=dxlevel(^D);
    if(qsourcesplit .eqv. ssplitresis) then
       ! Sources for resistivity in eqs. for e, B1, B2 and B3
       if(dabs(mhd_eta)>smalldouble)then
          if (.not.slab) call mpistop("no resistivity in non-slab geometry")
          if(compactres)then
             call addsource_res1(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
          else
             call addsource_res2(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
          end if
       end if

       if (mhd_eta_hyper>0.d0)then
          call addsource_hyperres(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
       end if
    end if

    {^NOONED
    if(qsourcesplit .eqv. ssplitdivb) then
       ! Sources related to div B
       select case (typedivbfix)
          {#IFDEF GLM
       case ('glm1')
          call addsource_glm1(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
       case ('glm2')
          call addsource_glm2(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D) 
       case ('glm3')
          call addsource_glm3(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)\}
       case ('powel')
          call addsource_powel(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
       case ('janhunen')
          call addsource_janhunen(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
       case ('linde')
          call addsource_linde(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
       case ('lindejanhunen')
          call addsource_linde(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
          call addsource_janhunen(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
       case ('lindepowel')
          call addsource_linde(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
          call addsource_powel(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
       end select
    end if
    }
  end subroutine mhd_add_source

  !> Add resistive source to w within ixO Uses 3 point stencil (1 neighbour) in
  !> each direction, non-conservative. If the fourthorder precompiler flag is
  !> set, uses fourth order central difference for the laplacian. Then the
  !> stencil is 5 (2 neighbours).
  subroutine addsource_res1(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
    use mod_global_parameters

    integer, intent(in)             :: ixI^L, ixO^L, iw^LIM
    double precision, intent(in)    :: qdt, qtC, qt
    double precision, intent(in) :: wCT(ixI^S,1:nw), x(ixI^S,1:ndim)
    double precision, intent(in)    :: dx^D
    double precision, intent(inout) :: w(ixI^S,1:nw)
    !.. local ..
    integer :: ix^L,idir,jdir,kdir,idirmin,iw,idims,jxO^L,hxO^L,ix
    {#IFDEF FOURTHORDER  integer :: lxO^L, kxO^L}

    double precision :: tmp(ixI^S),tmp2(ixI^S)

    ! For ndir=2 only 3rd component of J can exist, ndir=1 is impossible for MHD
    double precision :: current(ixI^S,7-2*ndir:3),eta(ixI^S)
    double precision :: gradeta(ixI^S,1:ndim)
    !-----------------------------------------------------------------------------

    {#IFNDEF FOURTHORDER
    ! Calculating resistive sources involve one extra layer
    ix^L=ixO^L^LADD1;
    }{#IFDEF FOURTHORDER
    ix^L=ixO^L^LADD2;
    }

    if(ixImin^D>ixmin^D.or.ixImax^D<ixmax^D|.or.) &
         call mpistop("Error in addsource_res1: Non-conforming input limits")

    ! Calculate current density and idirmin
    call getcurrent(wCT,ixI^L,ixO^L,idirmin,current)

    if(mhd_eta>zero)then
       eta(ix^S)=mhd_eta
       gradeta(ixO^S,1:ndim)=zero
    else
       call specialeta(wCT,ixI^L,ix^L,idirmin,x,current,eta)
       ! assumes that eta is not function of current?
       do idims=1,ndim
          call gradient(eta,ixI^L,ixO^L,idims,tmp)
          gradeta(ixO^S,idims)=tmp(ixO^S)
       end do
    end if

    do idir=1,ndir
       ! Put B_idir into tmp2 and eta*Laplace B_idir into tmp
       {#IFNDEF FOURTHORDER
       tmp(ixO^S)=zero
       tmp2(ixI^S)=wCT(ixI^S,b0_+idir)
       do idims=1,ndim
          jxO^L=ixO^L+kr(idims,^D);
          hxO^L=ixO^L-kr(idims,^D);
          tmp(ixO^S)=tmp(ixO^S)+&
               (tmp2(jxO^S)-2.0d0*tmp2(ixO^S)+tmp2(hxO^S))/dxlevel(idims)**2
       end do
       }
       {#IFDEF FOURTHORDER
       tmp(ixO^S)=zero
       tmp2(ixI^S)=wCT(ixI^S,b0_+idir)
       do idims=1,ndim
          lxO^L=ixO^L+2*kr(idims,^D);
          jxO^L=ixO^L+kr(idims,^D);
          hxO^L=ixO^L-kr(idims,^D);
          kxO^L=ixO^L-2*kr(idims,^D);
          tmp(ixO^S)=tmp(ixO^S)+&
               (-tmp2(lxO^S)+16.0d0*tmp2(jxO^S)-30.0d0*tmp2(ixO^S)+16.0d0*tmp2(hxO^S)-tmp2(kxO^S)) &
               /(12.0d0 * dxlevel(idims)**2)
       end do
       }

       ! Multiply by eta
       tmp(ixO^S)=tmp(ixO^S)*eta(ixO^S)

       ! Subtract grad(eta) x J = eps_ijk d_j eta J_k if eta is non-constant
       if(mhd_eta<zero)then
          do jdir=1,ndim; do kdir=idirmin,3
             if(lvc(idir,jdir,kdir)/=0)then
                if(lvc(idir,jdir,kdir)==1)then
                   tmp(ixO^S)=tmp(ixO^S)-gradeta(ixO^S,jdir)*current(ixO^S,kdir)
                else
                   tmp(ixO^S)=tmp(ixO^S)+gradeta(ixO^S,jdir)*current(ixO^S,kdir)
                end if
             end if
          end do; end do
       end if

       ! Add sources related to eta*laplB-grad(eta) x J to B and e
       do iw=1,nw
          if(iw==b0_+idir)then
             ! dB_idir/dt+=tmp
             w(ixO^S,iw)=w(ixO^S,iw)+qdt*tmp(ixO^S)
          else if(iw==e_)then
             ! de/dt+=B.tmp
             w(ixO^S,iw)=w(ixO^S,iw)+qdt*tmp(ixO^S)*wCT(ixO^S,b0_+idir)
          end if
       end do  ! iw
    end do ! idir

    if (mhd_energy) then
       ! de/dt+=eta*J**2
       tmp(ixO^S)=zero
       do idir=idirmin,3
          tmp(ixO^S)=tmp(ixO^S)+current(ixO^S,idir)**2
       end do
       w(ixO^S,e_)=w(ixO^S,e_)+qdt*eta(ixO^S)*tmp(ixO^S)

       if(fixsmall) call smallvalues(w,x,ixI^L,ixO^L,"addsource_res1")
    end if
  end subroutine addsource_res1

  !> Add resistive source to w within ixO 
  !> Uses 5 point stencil (2 neighbours) in each direction, conservative
  subroutine addsource_res2(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
    use mod_global_parameters

    integer, intent(in)             :: ixI^L, ixO^L, iw^LIM
    double precision, intent(in)    :: qdt, qtC, qt
    double precision, intent(in)    :: wCT(ixI^S,1:nw), x(ixI^S,1:ndim)
    double precision, intent(in)    :: dx^D
    double precision, intent(inout) :: w(ixI^S,1:nw)
    !.. local ..
    integer :: ix^L,idir,jdir,kdir,idirmin,iw,idims,idirmin1

    double precision :: tmp(ixI^S),tmp2(ixI^S)

    ! For ndir=2 only 3rd component of J can exist, ndir=1 is impossible for MHD
    double precision :: current(ixI^S,7-2*ndir:3),eta(ixI^S),curlj(ixI^S,1:3)
    double precision :: tmpvec(ixI^S,1:3),tmpvec2(ixI^S,1:ndir)
    !-----------------------------------------------------------------------------

    ix^L=ixO^L^LADD2;

    if(ixImin^D>ixmin^D.or.ixImax^D<ixmax^D|.or.) &
         call mpistop("Error in addsource_res2: Non-conforming input limits")

    ix^L=ixO^L^LADD1;
    ! Calculate current density within ixL: J=curl B, thus J_i=eps_ijk*d_j B_k
    ! Determine exact value of idirmin while doing the loop.
    call getcurrent(wCT,ixI^L,ix^L,idirmin,current)

    if(mhd_eta>zero)then
       eta(ix^S)=mhd_eta
    else
       call specialeta(wCT,ixI^L,ix^L,idirmin,x,current,eta)
    end if

    ! dB/dt= -curl(J*eta), thus B_i=B_i-eps_ijk d_j Jeta_k
    tmpvec(ix^S,1:ndir)=zero
    do jdir=idirmin,3
       tmpvec(ix^S,jdir)=current(ix^S,jdir)*eta(ix^S)*qdt
    end do
    call curlvector(tmpvec,ixI^L,ixO^L,curlj,idirmin1,1,3)
    {^C& w(ixO^S,b^C_) = w(ixO^S,b^C_)-curlj(ixO^S,b^C_-b0_)\}

    if (mhd_energy) then
       ! de/dt= +div(B x Jeta)
       tmpvec2(ix^S,1:ndir)=zero
       do idir=1,ndir; do jdir=1,ndir; do kdir=idirmin,3
          if(lvc(idir,jdir,kdir)/=0)then
             tmp(ix^S)=wCT(ix^S,b0_+jdir)*current(ix^S,kdir)*eta(ix^S)*qdt
             if(lvc(idir,jdir,kdir)==1)then
                tmpvec2(ix^S,idir)=tmpvec2(ix^S,idir)+tmp(ix^S)
             else
                tmpvec2(ix^S,idir)=tmpvec2(ix^S,idir)-tmp(ix^S)
             end if
          end if
       end do; end do; end do
       !select case(typediv)
       !case("central")
       call divvector(tmpvec2,ixI^L,ixO^L,tmp)
       !case("limited")
       !   call divvectorS(tmpvec2,ixI^L,ixO^L,tmp)
       !end select
       w(ixO^S,e_)=w(ixO^S,e_)+tmp(ixO^S)

       if(fixsmall) call smallvalues(w,x,ixI^L,ixO^L,"addsource_res2")
    end if
  end subroutine addsource_res2

  !> Add Hyper-resistive source to w within ixO 
  !> Uses 9 point stencil (4 neighbours) in each direction.
  subroutine addsource_hyperres(qdt,ixI^L,ixO^L,iw^LIM,qtC,wCT,qt,w,x,dx^D)
    use mod_global_parameters

    integer, intent(in)             :: ixI^L, ixO^L, iw^LIM
    double precision, intent(in)    :: qdt, qtC, qt
    double precision, intent(in)    :: wCT(ixI^S,1:nw), x(ixI^S,1:ndim)
    double precision, intent(in)    :: dx^D
    double precision, intent(inout) :: w(ixI^S,1:nw)
    !.. local ..
    double precision                :: current(ixI^S,7-2*ndir:3)
    double precision                :: tmpvec(ixI^S,1:3),tmpvec2(ixI^S,1:3),tmp(ixI^S),ehyper(ixI^S,1:3)
    integer                         :: ix^L,idir,jdir,kdir,idirmin,idirmin1
    !-----------------------------------------------------------------------------
    ix^L=ixO^L^LADD3;
    if(ixImin^D>ixmin^D.or.ixImax^D<ixmax^D|.or.) &
         call mpistop("Error in addsource_hyperres: Non-conforming input limits")

    call getcurrent(wCT,ixI^L,ix^L,idirmin,current)
    tmpvec(ix^S,1:ndir)=zero
    do jdir=idirmin,3
       tmpvec(ix^S,jdir)=current(ix^S,jdir)
    end do

    ix^L=ixO^L^LADD2;
    call curlvector(tmpvec,ixI^L,ix^L,tmpvec2,idirmin1,1,3)

    ix^L=ixO^L^LADD1;
    tmpvec(ix^S,1:ndir)=zero
    call curlvector(tmpvec2,ixI^L,ix^L,tmpvec,idirmin1,1,3)
    ehyper(ix^S,1:ndir) = - tmpvec(ix^S,1:ndir)*mhd_eta_hyper

    ix^L=ixO^L;
    tmpvec2(ix^S,1:ndir)=zero
    call curlvector(ehyper,ixI^L,ix^L,tmpvec2,idirmin1,1,3)

    {^C& w(ixO^S,b^C_) = w(ixO^S,b^C_)-tmpvec2(ixO^S,^C)*qdt\}

    if (mhd_energy) then
       ! de/dt= +div(B x Ehyper)
       ix^L=ixO^L^LADD1;
       tmpvec2(ix^S,1:ndir)=zero
       do idir=1,ndir; do jdir=1,ndir; do kdir=idirmin,3
          tmpvec2(ix^S,idir) = tmpvec(ix^S,idir)&
               + lvc(idir,jdir,kdir)*wCT(ix^S,b0_+jdir)*ehyper(ix^S,kdir)
       end do; end do; end do
       tmp(ixO^S)=zero
       call divvector(tmpvec2,ixI^L,ixO^L,tmp)
       w(ixO^S,e_)=w(ixO^S,e_)+tmp(ixO^S)*qdt

       if(fixsmall) call smallvalues(w,x,ixI^L,ixO^L,"addsource_hyperres")
    end if
  end subroutine addsource_hyperres

  !> Calculate idirmin and the idirmin:3 components of the common current array
  !> make sure that dxlevel(^D) is set correctly.
  subroutine getcurrent(w,ixI^L,ix^L,idirmin,current)
    use mod_global_parameters

    integer, parameter:: idirmin0=7-2*ndir
    integer :: ix^L, idirmin, ixI^L
    double precision :: w(ixI^S,1:nw)

    ! For ndir=2 only 3rd component of J can exist, ndir=1 is impossible for MHD
    double precision :: current(ixI^S,7-2*ndir:3),bvec(ixI^S,1:ndir)

    if(B0field) then
       ^C&bvec(ixI^S,^C)=w(ixI^S,b^C_)+myB0_cell%w(ixI^S,^C);
    else
       ^C&bvec(ixI^S,^C)=w(ixI^S,b^C_);
    end if
    !bvec(ixI^S,1:ndir)=w(ixI^S,b0_+1:b0_+ndir)
    call curlvector(bvec,ixI^L,ix^L,current,idirmin,idirmin0,ndir)

  end subroutine getcurrent

  !> If resistivity is not zero, check diffusion time limit for dt
  subroutine mhd_get_dt(w,ixI^L,ix^L,dtnew,dx^D,x)
    use mod_global_parameters

    integer, intent(in)           :: ixI^L, ix^L
    double precision, intent(out) :: dtnew
    double precision, intent(in)  :: dx^D
    double precision, intent(in)  :: w(ixI^S,1:nw)
    double precision, intent(in)  :: x(ixI^S,1:ndim)
    !.. local ..
    integer                       :: idirmin,idims
    double precision              :: dxarr(ndim)
    double precision              :: current(ixI^S,7-2*ndir:3),eta(ixI^S) 
    !-----------------------------------------------------------------------------
    dtnew = bigdouble

    ^D&dxarr(^D)=dx^D;
    ^D&dxlevel(^D)=dx^D;
    if(mhd_eta>zero)then
       dtnew=dtdiffpar*minval(dxarr(1:ndim))**2/mhd_eta
    else if(mhd_eta<zero)then
       call getcurrent(w,ixI^L,ix^L,idirmin,current)
       call specialeta(w,ixI^L,ix^L,idirmin,x,current,eta)
       dtnew=bigdouble
       do idims=1,ndim
          dtnew=min(dtnew,&
               dtdiffpar/(smalldouble+maxval(eta(ix^S)/dxarr(idims)**2)))
       end do
    end if

    if(mhd_eta_hyper>zero)then
       dtnew=min(dtdiffpar*minval(dxarr(1:ndim))**4/mhd_eta_hyper,dtnew)
    end if

  end subroutine mhd_get_dt

  ! Add geometrical source terms to w
  subroutine mhd_add_source_geom(qdt,ixI^L,ixO^L,wCT,w,x)
    use mod_global_parameters

    integer, intent(in)             :: ixI^L, ixO^L
    double precision, intent(in)    :: qdt, x(ixI^S,1:ndim)
    double precision, intent(inout) :: wCT(ixI^S,1:nw), w(ixI^S,1:nw)
    !.. local ..
    integer          :: iw,idir, h1x^L{^NOONED, h2x^L}
    double precision :: tmp(ixI^S)
    logical          :: angmomfix=.false.
    !-----------------------------------------------------------------------------

    ! TODO
    ! INTEGER,PARAMETER:: mr_=m0_+r_,mphi_=m0_+phi_,mz_=m0_+z_  ! Polar var. names
    ! integer,parameter:: br_=b0_+r_,bphi_=b0_+phi_,bz_=b0_+z_


    ! select case (typeaxial)
    ! case ('slab')
    !    ! No source terms in slab symmetry
    ! case ('cylindrical')
    !    do iw=1,nwflux
    !       select case (iw)
    !          ! s[mr]=(ptotal-Bphi**2+mphi**2/rho)/radius
    !       case (mr_)
    !          call getptotal(wCT,x,ixI^L,ixO^L,tmp)
    !          w(ixO^S,iw)=w(ixO^S,iw)+qdt*tmp(ixO^S)/x(ixO^S,1)
    !          tmp(ixO^S)=zero
    !          {^IFPHI
    !          tmp(ixO^S)= &
    !               -wCT(ixO^S,bphi_)**2+wCT(ixO^S,mphi_)**2/wCT(ixO^S,rho_)

    !          ! s[mphi]=(-mphi*mr/rho+Bphi*Br)/radius
    !       case (mphi_)
    !          tmp(ixO^S)= &
    !               -wCT(ixO^S,mphi_)*wCT(ixO^S,mr_)/wCT(ixO^S,rho_) &
    !               +wCT(ixO^S,bphi_)*wCT(ixO^S,br_)

    !          ! s[Bphi]=((Bphi*mr-Br*mphi)/rho)/radius
    !       case (bphi_)
    !          tmp(ixO^S)=(wCT(ixO^S,bphi_)*wCT(ixO^S,mr_) &
    !               -wCT(ixO^S,br_)*wCT(ixO^S,mphi_)) &
    !               /wCT(ixO^S,rho_)
    !          }
    !          {#IFDEF GLM      ! s[br]=psi/radius
    !       case (br_)
    !          tmp(ixO^S)=wCT(ixO^S,psi_)
    !          }
    !       end select

    !       ! Divide by radius and add to w
    !       if (iw==mr_{#IFDEF GLM .or.iw==br_}{^IFPHI .or.iw==mphi_.or.iw==bphi_}) then
    !          w(ixO^S,iw)=w(ixO^S,iw)+qdt*tmp(ixO^S)/x(ixO^S,1)
    !       end if

    !    end do
    ! case ('spherical')
    !    h1x^L=ixO^L-kr(1,^D); {^NOONED h2x^L=ixO^L-kr(2,^D);}
    !    do iw=1,nwflux
    !       select case (iw)
    !          ! s[m1]=((mtheta**2+mphi**2)/rho+2*ptotal-(Btheta**2+Bphi**2))/r
    !       case (m1_)
    !          call getptotal(wCT,x,ixI^L,ixO^L,tmp)
    !          if (B0field) then
    !             tmp(ixO^S)=tmp(ixO^S)+{^C&myB0_cell%w(ixO^S,^C)*wCT(ixO^S,b^C_)+}
    !          end if
    !          ! For nonuniform Cartesian grid this provides hydrostatic equil.
    !          tmp(ixO^S)=tmp(ixO^S)*x(ixO^S,1) &
    !               *(mygeo%surfaceC1(ixO^S)-mygeo%surfaceC1(h1x^S)) &
    !               /mygeo%dvolume(ixO^S){&^CE&
    !               +wCT(ixO^S,m^CE_)**2/wCT(ixO^S,rho_)-wCT(ixO^S,b^CE_)**2 }
    !          if (B0field.and.ndir>1) then
    !             tmp(ixO^S)=tmp(ixO^S){^CE&-2.0d0*myB0_cell%w(ixO^S,^CE) &
    !                  *wCT(ixO^S,b^CE_)|}
    !          end if
    !          {^NOONEC
    !          ! s[m2]=-(mr*mtheta/rho-Br*Btheta)/r
    !          !       + cot(theta)*(mphi**2/rho+(p+0.5*B**2)-Bphi**2)/r
    !       case (m2_)
    !          }
    !          {^NOONED
    !          call getptotal(wCT,x,ixI^L,ixO^L,tmp)
    !          if (B0field) then
    !             tmp(ixO^S)=tmp(ixO^S)+{^C&myB0_cell%w(ixO^S,^C)*wCT(ixO^S,b^C_)+}
    !          end if
    !          ! This will make hydrostatic p=const an exact solution
    !          w(ixO^S,iw)=w(ixO^S,iw)+qdt*tmp(ixO^S) &
    !               *(mygeo%surfaceC2(ixO^S)-mygeo%surfaceC2(h2x^S)) &
    !               /mygeo%dvolume(ixO^S)
    !          }
    !          {^NOONEC
    !          tmp(ixO^S)=-(wCT(ixO^S,m1_)*wCT(ixO^S,m2_)/wCT(ixO^S,rho_) &
    !               -wCT(ixO^S,b1_)*wCT(ixO^S,b2_))
    !          if (B0field) then
    !             tmp(ixO^S)=tmp(ixO^S)+myB0_cell%w(ixO^S,1)*wCT(ixO^S,b2_) &
    !                  +wCT(ixO^S,b1_)*myB0_cell%w(ixO^S,2)
    !          end if
    !          }
    !          {^IFTHREEC
    !          {^NOONED
    !          tmp(ixO^S)=tmp(ixO^S)+(wCT(ixO^S,m3_)**2/wCT(ixO^S,rho_) &
    !               -wCT(ixO^S,b3_)**2)*dcos(x(ixO^S,2)) &
    !               /dsin(x(ixO^S,2))
    !          if (B0field) then
    !             tmp(ixO^S)=tmp(ixO^S)-2.0d0*myB0_cell%w(ixO^S,3)*wCT(ixO^S,b3_)&
    !                  *dcos(x(ixO^S,2))/dsin(x(ixO^S,2))
    !          end if
    !          }
    !          ! s[m3]=-(mphi*mr/rho-Bphi*Br)/r
    !          !       -cot(theta)*(mtheta*mphi/rho-Btheta*Bphi)/r
    !       case (m3_)
    !          if (.not.angmomfix) then
    !             tmp(ixO^S)=-(wCT(ixO^S,m3_)*wCT(ixO^S,m1_)/wCT(ixO^S,rho_) &
    !                  -wCT(ixO^S,b3_)*wCT(ixO^S,b1_)) {^NOONED &
    !                  -(wCT(ixO^S,m2_)*wCT(ixO^S,m3_)/wCT(ixO^S,rho_) &
    !                  -wCT(ixO^S,b2_)*wCT(ixO^S,b3_)) &
    !                  *dcos(x(ixO^S,2))/dsin(x(ixO^S,2)) }
    !             if (B0field) then
    !                tmp(ixO^S)=tmp(ixO^S)+myB0_cell%w(ixO^S,1)*wCT(ixO^S,b3_) &
    !                     +wCT(ixO^S,b1_)*myB0_cell%w(ixO^S,3) {^NOONED &
    !                     +(myB0_cell%w(ixO^S,2)*wCT(ixO^S,b3_) &
    !                     +wCT(ixO^S,b2_)*myB0_cell%w(ixO^S,3)) &
    !                     *dcos(x(ixO^S,2))/dsin(x(ixO^S,2)) }
    !             end if
    !          end if
    !          }
    !          {#IFDEF GLM
    !          ! s[b1]=2*psi/r
    !       case (b1_)
    !          tmp(ixO^S)=2.0d0*wCT(ixO^S,psi_)
    !          }
    !          {^NOONEC
    !          ! s[b2]=(mr*Btheta-mtheta*Br)/rho/r
    !          !       + cot(theta)*psi/r
    !       case (b2_)
    !          tmp(ixO^S)=(wCT(ixO^S,m1_)*wCT(ixO^S,b2_) &
    !               -wCT(ixO^S,m2_)*wCT(ixO^S,b1_))/wCT(ixO^S,rho_)
    !          if (B0field) then
    !             tmp(ixO^S)=tmp(ixO^S)+(wCT(ixO^S,m1_)*myB0_cell%w(ixO^S,2) &
    !                  -wCT(ixO^S,m2_)*myB0_cell%w(ixO^S,1))/wCT(ixO^S,rho_)
    !          end if
    !          {#IFDEF GLM
    !          tmp(ixO^S)=tmp(ixO^S) &
    !               + dcos(x(ixO^S,2))/dsin(x(ixO^S,2))*wCT(ixO^S,psi_)
    !          }
    !          }
    !          {^IFTHREEC
    !          ! s[b3]=(mr*Bphi-mphi*Br)/rho/r
    !          !       -cot(theta)*(mphi*Btheta-mtheta*Bphi)/rho/r
    !       case (b3_)
    !          tmp(ixO^S)=(wCT(ixO^S,m1_)*wCT(ixO^S,b3_) &
    !               -wCT(ixO^S,m3_)*wCT(ixO^S,b1_))/wCT(ixO^S,rho_) {^NOONED &
    !               -(wCT(ixO^S,m3_)*wCT(ixO^S,b2_) &
    !               -wCT(ixO^S,m2_)*wCT(ixO^S,b3_))*dcos(x(ixO^S,2)) &
    !               /(wCT(ixO^S,rho_)*dsin(x(ixO^S,2))) }
    !          if (B0field) then
    !             tmp(ixO^S)=tmp(ixO^S)+(wCT(ixO^S,m1_)*myB0_cell%w(ixO^S,3) &
    !                  -wCT(ixO^S,m3_)*myB0_cell%w(ixO^S,1))/wCT(ixO^S,rho_){^NOONED &
    !                  -(wCT(ixO^S,m3_)*myB0_cell%w(ixO^S,2) &
    !                  -wCT(ixO^S,m2_)*myB0_cell%w(ixO^S,3))*dcos(x(ixO^S,2)) &
    !                  /(wCT(ixO^S,rho_)*dsin(x(ixO^S,2))) }
    !          end if
    !          }
    !       end select
    !       ! Divide by radius and add to w
    !       if (iw==m1_{#IFDEF GLM .or.iw==b1_}{^NOONEC.or.iw==m2_.or.iw==b2_}&
    !            {^IFTHREEC .or.iw==b3_ .or.(iw==m3_.and..not.angmomfix)}) &
    !            w(ixO^S,iw)=w(ixO^S,iw)+qdt*tmp(ixO^S)/x(ixO^S,1)
    !    end do
    ! end select
  end subroutine mhd_add_source_geom

  ! TODO: rewrite
  subroutine smallvalues(w,x,ixI^L,ixO^L,subname)

    use mod_global_parameters

    integer, intent(in)             :: ixI^L,ixO^L
    double precision, intent(inout) :: w(ixI^S,1:nw)
    double precision, intent(in)    :: x(ixI^S,1:ndim)
    character(len=*), intent(in)    ::subname
    !.. local ..
    integer                         :: posvec(ndim)
    integer, dimension(ixI^S)       :: patchierror
    double precision                :: pth(ixI^S), Te(ixI^S)
    !-----------------------------------------------------------------------------

    {#IFDEF ENERGY
    pth(ixO^S)=(mhd_gamma-one)*(w(ixO^S,e_)- &
         half*(({^C&w(ixO^S,m^C_)**2+})/w(ixO^S,rho_)&
         +{ ^C&w(ixO^S,b^C_)**2+}))
    if(smallT>0.d0) then
       Te(ixO^S)=pth(ixO^S)/w(ixO^S,rho_)
    else
       Te(ixO^S)=zero
    end if
    if(strictsmall) then
       if(smallT>0.d0 .and. any(Te(ixO^S) <=smallT)) then
          print *,'SMALLVALUES of temperature under strictsmall problem From:  ', &
               subname,' iteration=', it,' time=',t
          posvec(1:ndim)=minloc(Te(ixO^S))
          ^D&posvec(^D)=posvec(^D)+ixOmin^D-1;
          write(*,*)'minimum temperature= ', minval(Te(ixO^S)),' with limit=',smallT,&
               ' at x=', x(^D&posvec(^D),1:ndim),' array index=',posvec,' where rho=',&
               w({^D&posvec(^D)},rho_),', velocity v=',&
               ^C&w({^D&posvec(^D)},m^C_)/w({^D&posvec(^D)},rho_),&
               ', and magnetic field B=',^C&w({^D&posvec(^D)},b^C_),&
               ' w(1:nwflux)=',w(^D&posvec(^D),1:nwflux)
          call mpistop("Smallvalues of temperature with strictsmall=T failed")
       end if
       if(any(pth(ixO^S) <=minp)) then
          print *,'SMALLVALUES of pressure under strictsmall problem From:  ', &
               subname,' iteration=', it,' time=',t
          posvec(1:ndim)=minloc(pth(ixO^S))
          ^D&posvec(^D)=posvec(^D)+ixOmin^D-1;
          write(*,*)'minimum pressure = ', minval(pth(ixO^S)),' with limit=',minp,&
               ' at x=', x(^D&posvec(^D),1:ndim),' array index=',posvec,' where rho=',&
               w({^D&posvec(^D)},rho_),', velocity v=',&
               ^C&w({^D&posvec(^D)},m^C_)/w({^D&posvec(^D)},rho_),&
               ', and magnetic field B=',^C&w({^D&posvec(^D)},b^C_),&
               ' w(1:nwflux)=',w(^D&posvec(^D),1:nwflux)
          call mpistop("Smallvalues of pressure with strictsmall=T failed")
       end if
       if(any(w(ixO^S,e_) <=smalle)) then
          print *,'SMALLVALUES of energy under strictsmall problem From:  ', &
               subname,' iteration=', it,' time=',t
          posvec(1:ndim)=minloc(w(ixO^S,e_))
          ^D&posvec(^D)=posvec(^D)+ixOmin^D-1;
          write(*,*)'minimum e =', minval(w(ixO^S,e_)),' with limit=',smalle,&
               ' at x=', x(^D&posvec(^D),1:ndim),' array index=',posvec,' where E_k=',&
               half*(^C&w(^D&posvec(^D),m^C_)**2+)/w(^D&posvec(^D),rho_),&
               ' E_total=',w(^D&posvec(^D),e_),&
               ' w(1:nwflux)=',w(^D&posvec(^D),1:nwflux)
          call mpistop("Smallvalues of energy with strictsmall=T failed")
       end if
       if(any(w(ixO^S,rho_) <=minrho)) then
          print *,'SMALLVALUES of density under strictsmall problem From:  ', &
               subname,' iteration=', it,' time=',t
          posvec(1:ndim)=minloc(w(ixO^S,rho_))
          ^D&posvec(^D)=posvec(^D)+ixOmin^D-1;
          write(*,*)'minimum rho =', minval(w(ixO^S,rho_)),' with limit=',minrho,&
               ' at x=', x(^D&posvec(^D),1:ndim),' array index=',posvec,' where E_k=',&
               half*(^C&w(^D&posvec(^D),m^C_)**2+)/w(^D&posvec(^D),rho_),&
               ' E_total=',w(^D&posvec(^D),e_),&
               ' w(1:nwflux)=',w(^D&posvec(^D),1:nwflux)
          call mpistop("Smallvalues of density with strictsmall=T failed")
       end if
    else
       if(strictgetaux)then
          where(w(ixO^S,rho_) < minrho)
             w(ixO^S,rho_)=minrho
             {^C&w(ixO^S,m^C_) =zero;}
          end where
          where(pth(ixO^S) < minp)
             w(ixO^S,e_)=minp/(mhd_gamma-one)+&
                  (({^C&w(ixO^S,m^C_)**2+})/w(ixO^S,rho_)+{^C&w(ixO^S,b^C_)**2+})*half
          end where
          where(Te(ixO^S) < smallT)
             w(ixO^S,e_)=smallT*w(ixO^S,rho_)/(mhd_gamma-one)+&
                  (({^C&w(ixO^S,m^C_)**2+})/w(ixO^S,rho_)+{^C&w(ixO^S,b^C_)**2+})*half
          end where
       else
          where(w(ixO^S,rho_) < minrho .or. w(ixO^S,e_) < smalle&
               .or. pth(ixO^S) < minp .or. Te(ixO^S) < smallT)
             patchierror(ixO^S)=-1
          elsewhere
             patchierror(ixO^S)=0
          end where
          call correctaux(ixI^L,ixO^L,w,x,patchierror,subname)
       end if
    end if
    }

    {#IFDEF ISO
    if(any(w(ixO^S,rho_) < minrho)) then
       if(strictsmall)then
          write(*,*)'SMALLVALUES of density under strictsmall problem From:  ', &
               subname,' iteration ', it,' time ',t
          posvec(1:ndim)=minloc(w(ixO^S,rho_))
          ^D&posvec(^D)=posvec(^D)+ixOmin^D-1;
          write(*,*)'minimum rho =', minval(w(ixO^S,rho_)),' with limit=',minrho,&
               ' at x=', x(^D&posvec(^D),1:ndim),' array index=',posvec,' where E_k=',&
               half*(^C&w(^D&posvec(^D),m^C_)**2+)/w(^D&posvec(^D),rho_),&
               ' w(1:nwflux)=',w(^D&posvec(^D),1:nwflux)
          call mpistop("Smallvalues of density with strictsmall=T failed")
       else
          if(strictgetaux)then
             where(w(ixO^S,rho_) < minrho)
                w(ixO^S,rho_)  = 2.0*(1.0d0 + 10.0d0 * minrho)*minrho
             end where
          else
             where(w(ixO^S,rho_) < minrho)
                patchierror(ixO^S)=-1
             elsewhere
                patchierror(ixO^S)=0
             end where
             call correctaux(ixI^L,ixO^L,w,x,patchierror,subname)
          end if
       end if ! strict
    end if
    }
  end subroutine smallvalues

  !> This implements eq. (42) in Dedner et al. 2002 JcP 175
  !> Gives the Riemann solution on the interface
  !> for the normal B component and Psi in the GLM-MHD system.
  !> 23/04/2013 Oliver Porth
  subroutine glmSolve(wLC,wRC,ixI^L,ixO^L,idir)
    use mod_global_parameters
    double precision, intent(inout) :: wLC(ixI^S,1:nw), wRC(ixI^S,1:nw)
    integer, intent(in)             :: ixI^L, ixO^L, idir
    double precision                :: dB(ixI^S), dPsi(ixI^S)

    !BL(ixO^S) = wLC(ixO^S,b0_+idir)
    !BR(ixO^S) = wRC(ixO^S,b0_+idir)

    !PsiL(ixO^S) = wLC(ixO^S,psi_)
    !PsiR(ixO^S) = wRC(ixO^S,psi_)

    dB(ixO^S)   = wRC(ixO^S,b0_+idir) - wLC(ixO^S,b0_+idir)
    dPsi(ixO^S) = wRC(ixO^S,psi_) - wLC(ixO^S,psi_)

    wLC(ixO^S,b0_+idir)   = 0.5d0 * (wRC(ixO^S,b0_+idir) + wLC(ixO^S,b0_+idir)) &
         - half/cmax_global * dPsi(ixO^S)
    wLC(ixO^S,psi_)       = 0.5d0 * (wRC(ixO^S,psi_) + wLC(ixO^S,psi_)) &
         - half*cmax_global * dB(ixO^S)

    wRC(ixO^S,b0_+idir) = wLC(ixO^S,b0_+idir)
    wRC(ixO^S,psi_) = wLC(ixO^S,psi_)

  end subroutine glmSolve

end module mod_mhd_phys
