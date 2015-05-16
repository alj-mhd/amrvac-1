!============================================================================= 
subroutine magnetofriction

include 'amrvacdef.f'

integer :: i,iigrid, igrid
double precision :: tmf,dtfff,dtfff_pe,dtnew,vhatmax,vhatmax_pe,vhatmaxgrid,dx^D
logical :: patchw(ixG^T)
!-----------------------------------------------------------------------------

if(mype==0) write(*,*) 'Evolving to force-free field using &
                     magnetofricitonal method...'
do iigrid=1,igridstail; igrid=igrids(iigrid);
   pwold(igrid)%w(ixG^T,v0_+1:v0_+ndir)=pw(igrid)%w(ixG^T,v0_+1:v0_+ndir)
end do

tmf=0.d0
dtfff=1.d-2
! magnetofrictional cycling
i=0
do
  call getbc(t,ixG^LL,pw,pwCoarse,pgeo,pgeoCoarse,.false.)
  vhatmax_pe=smalldouble
  do iigrid=1,igridstail; igrid=igrids(iigrid);
    if (.not.slab) mygeo => pgeo(igrid)
    if (B0field) then
       myB0_cell => pB0_cell(igrid)
       {^D&myB0_face^D => pB0_face^D(igrid)\}
    end if
    !typelimiter=typelimiter1(node(plevel_,igrid))
    !typegradlimiter=typegradlimiter1(node(plevel_,igrid))
    ^D&dxlevel(^D)=rnode(rpdx^D_,igrid);
    call vhat(pw(igrid)%w,px(igrid)%x,ixG^LL,ixM^LL,vhatmaxgrid)
    vhatmax_pe=max(vhatmax_pe,vhatmaxgrid)
  end do
  call MPI_ALLREDUCE(vhatmax_pe,vhatmax,1,MPI_DOUBLE_PRECISION,MPI_MAX, &
                         icomm,ierrmpi)
  dtfff_pe=bigdouble
  do iigrid=1,igridstail; igrid=igrids(iigrid);
    if (.not.slab) mygeo => pgeo(igrid)
    if (B0field) then
       myB0_cell => pB0_cell(igrid)
       {^D&myB0_face^D => pB0_face^D(igrid)\}
    end if
    typelimiter=typelimiter1(node(plevel_,igrid))
    typegradlimiter=typegradlimiter1(node(plevel_,igrid))
    ^D&dxlevel(^D)=rnode(rpdx^D_,igrid);
    ! calculate frictional velocity
    call frictional_velocity(pw(igrid)%w,px(igrid)%x,ixG^LL,ixM^LL,vhatmax,dtfff)
    ! calculate time step based on Cmax=alfven speed + frictional speed
    call getdtfff_courant(pw(igrid)%w,px(igrid)%x,ixG^LL,ixM^LL,dtnew)
    dtfff_pe=min(dtfff_pe,dtnew)
  end do
  call MPI_ALLREDUCE(dtfff_pe,dtfff,1,MPI_DOUBLE_PRECISION,MPI_MIN, &
                     icomm,ierrmpi)
  call advectmf(1,ndim,tmf,dtfff)
  !do iigrid=1,igridstail; igrid=igrids(iigrid);
  !  if (.not.slab) mygeo => pgeo(igrid)
  !  if (B0field) then
  !     myB0_cell => pB0_cell(igrid)
  !     {^D&myB0_face^D => pB0_face^D(igrid)\}
  !  end if
  !  typelimiter=typelimiter1(node(plevel_,igrid))
  !  typegradlimiter=typegradlimiter1(node(plevel_,igrid))
  !  ^D&dxlevel(^D)=rnode(rpdx^D_,igrid);
  !  dx^D=rnode(rpdx^D_,igrid);
  !  call divbclean_linde(ixG^LL,ixM^LL,pw(igrid)%w,px(igrid)%x)
  !!  call evolve_centdiff4(dtfff,ixG^LL,ixM^LL,pw(igrid)%w,pw(igrid)%w,&
  !!       fC,dx^D,px(igrid)%x)
  !end do
  i=i+1
  tmf=tmf+dtfff
  if(mod(dble(i),dble(mfitmax/10))==0.d0 .and. mype==0) &
    write(*,*) "mfit=", i 
  if (i>=mfitmax) exit
enddo

!! restore initial velocity
!do iigrid=1,igridstail; igrid=igrids(iigrid);
!   pw(igrid)%w(ixG^T,v0_+1:v0_+ndir)=pwold(igrid)%w(ixG^T,v0_+1:v0_+ndir)
!end do

end subroutine magnetofriction
!=============================================================================
subroutine advectmf(idim^LIM,qt,qdt)

!  integrate all grids by one step of its delta(t)

! This subroutine is in VAC terminology equivalent to
! `advect' (with the difference that it will `advect' all grids)

include 'amrvacdef.f'

integer, intent(in) :: idim^LIM
double precision, intent(in) :: qt, qdt

integer :: iigrid, igrid
character*79 :: typeadvancemf
!-----------------------------------------------------------------------------
! copy w instead of wold because of potential use of dimsplit or sourcesplit
do iigrid=1,igridstail; igrid=igrids(iigrid);
   allocate (pw1(igrid)%w(ixG^T,1:nw))
   pw1(igrid)%w=pw(igrid)%w
end do
istep=0
typeadvancemf='threestep'
select case (typeadvancemf)
case ("onestep")
   call advect1mf(qdt,one,    idim^LIM,qt,          pw1,qt,pw, pwold)
case ("twostep")
   ! predictor step
   call advect1mf(qdt,half,   idim^LIM,qt,          pw,qt,pw1,pwold)
   ! corrector step
   call advect1mf(qdt,one,    idim^LIM,qt+half*qdt, pw1,qt,pw, pwold)
case ("threestep")
   ! three step Runge-Kutta in accordance with Gottlieb & Shu 1998
   call advect1mf(qdt,one,    idim^LIM,qt,          pw ,qt,pw1,pwold)

   do iigrid=1,igridstail; igrid=igrids(iigrid);
      allocate (pw2(igrid)%w(ixG^T,1:nw))
      pw2(igrid)%w(ixG^T,1:nwflux)=0.75d0*pw(igrid)%w(ixG^T,1:nwflux)+0.25d0*&
        pw1(igrid)%w(ixG^T,1:nwflux)
   end do

   call advect1mf(qdt,0.25d0, idim^LIM,qt+qdt,pw1,qt+dt*0.25d0,pw2,pwold)

   do iigrid=1,igridstail_active; igrid=igrids_active(iigrid);
      pw(igrid)%w(ixG^T,1:nwflux)=1.0d0/3.0d0*pw(igrid)%w(ixG^T,1:nwflux)+&
        2.0d0/3.0d0*pw2(igrid)%w(ixG^T,1:nwflux)
   end do   
   call advect1mf(qdt,2.0d0/3.0d0, idim^LIM,qt+qdt/2.0d0,pw2,&
          qt+qdt/3.0d0,pw,pwold)
case default
   write(unitterm,*) "typeadvancemf=",typeadvancemf
   write(unitterm,*) "Error in advect: Unknown time integration method"
   call mpistop("Correct typeadvancemf")
end select

do iigrid=1,igridstail; igrid=igrids(iigrid);
   deallocate (pw1(igrid)%w)
   select case (typeadvancemf)
     case ("threestep")
       deallocate (pw2(igrid)%w)
   end select
end do

end subroutine advectmf
!=============================================================================
subroutine advect1mf(dtin,dtfactor,idim^LIM,qtC,pwa,qt,pwb,pwc)

!  integrate all grids by one partial step

! This subroutine is equivalent to VAC's `advect1', but does
! the advection for all grids
include 'amrvacdef.f'

integer, intent(in) :: idim^LIM
double precision, intent(in) :: dtin,dtfactor, qtC, qt
type(walloc) :: pwa(ngridshi), pwb(ngridshi), pwc(ngridshi)

double precision :: qdt
integer :: iigrid, igrid, level

logical :: setigrid

!-----------------------------------------------------------------------------
istep=istep+1

if (levmax>levmin) then
   if (istep==nstep.or.nstep>2) &
        call init_comm_fix_conserve(idim^LIM)
end if

! loop over all grids to arrive at equivalent

! opedit: Just advance the active grids: 
qdt=dtfactor*dtin
do iigrid=1,igridstail; igrid=igrids(iigrid);
   level=node(plevel_,igrid)
   
   call process1_gridmf(igrid,qdt,ixG^LL,idim^LIM,qtC,&
                   pwa(igrid)%w,qt,pwb(igrid)%w,pwc(igrid)%w)
                   
end do

! opedit: Send flux for all grids, expects sends for all 
! nsend_fc(^D), set in connectivity.t.

if (time_advance.and.levmax>levmin) then
   if (istep==nstep.or.nstep>2) then
      do iigrid=1,igridstail; igrid=igrids(iigrid);
         call sendflux(igrid,idim^LIM)
      end do
      call fix_conserve(pwb,idim^LIM)
   end if
end if
   
! for all grids: fill ghost cells
qdt=dtfactor*dt
call getbc(qt+qdt,ixG^LL,pwb,pwCoarse,pgeo,pgeoCoarse,.false.)

end subroutine advect1mf
!=============================================================================
subroutine process1_gridmf(igrid,qdt,ixG^L,idim^LIM,qtC,wCT,qt,w,wold)

! This subroutine is equivalent to VAC's `advect1' for one grid

include 'amrvacdef.f'

integer, intent(in) :: igrid, ixG^L, idim^LIM
double precision, intent(in) :: qdt, qtC, qt
double precision :: wCT(ixG^S,1:nw), w(ixG^S,1:nw), wold(ixG^S,1:nw)

double precision :: dx^D
double precision :: fC(ixG^S,1:nwflux,1:ndim)
integer :: ixO^L
!-----------------------------------------------------------------------------
dx^D=rnode(rpdx^D_,igrid);
^D&dxlevel(^D)=rnode(rpdx^D_,igrid);
saveigrid=igrid

if (.not.slab) mygeo => pgeo(igrid)
if (B0field) then
   myB0_cell => pB0_cell(igrid)
   {^D&myB0_face^D => pB0_face^D(igrid)\}
end if
typelimiter=typelimiter1(node(plevel_,igrid))
typegradlimiter=typegradlimiter1(node(plevel_,igrid))

ixO^L=ixG^L^LSUBdixB;
call tvdlfmf(qdt,ixG^L,ixO^L,idim^LIM,qtC,wCT,qt,w,wold,fC,dx^D,px(igrid)%x)

if (levmax>levmin) then
   if (istep==nstep.or.nstep>2) &
        call storeflux(igrid,fC,idim^LIM)
end if

end subroutine process1_gridmf
!=============================================================================
subroutine getfluxmf(w,x,ixI^L,ixO^L,iw,idims,f,transport)

! Calculate non-transport flux f_idim[iw] within ixO^L.

include 'amrvacdef.f'

integer, intent(in)             :: ixI^L, ixO^L, iw, idims
double precision, intent(in)    :: w(ixI^S,nw)
double precision, intent(in)    :: x(ixI^S,1:ndim)
double precision,intent(out)    :: f(ixG^T)
!.. local ..
logical :: transport
integer :: idirmin, idir
!-----------------------------------------------------------------------------
transport=.true.

select case (iw)
   ! f_i[b_k]=v_i*b_k-m_k/rho*b_i
   {case (b^C_)
      if (idims==^C) then
         ! f_i[b_i] should be exactly 0, so we do not use the transport flux
         f(ixO^S)=zero
         transport=.false.
      else
         f(ixO^S)= -w(ixO^S,b0_+idims)*w(ixO^S,v0_+^C)
         if (B0field) then
            f(ixO^S)=f(ixO^S) &
                     +w(ixO^S,v0_+idims)*myB0%w(ixO^S,^C) &
                     -myB0%w(ixO^S,idims)*w(ixO^S,v0_+^C)
         end if
      end if\}
end select

end subroutine getfluxmf
!============================================================================= 
subroutine frictional_velocity(w,x,ixI^L,ixO^L,qvmax,qdt)

include 'amrvacdef.f'

integer, intent(in) :: ixI^L, ixO^L
double precision, intent(in) :: x(ixI^S,1:ndim),qdt,qvmax
double precision, intent(inout) :: w(ixI^S,1:nw)

double precision :: dxhm,disbd(5),bfzone^D
integer :: ix^D
!-----------------------------------------------------------------------------
dxhm=dble(ndim)/(^D&1.0d0/dxlevel(^D)+)
dxhm=cmf_c*cmf_y/qvmax*dxhm/qdt
^C&w(ixO^S,v0_+^C)=w(ixO^S,v0_+^C)*dxhm;
bfzone1=0.05d0*(xprobmax1-xprobmin1)
bfzone2=0.05d0*(xprobmax2-xprobmin2)
bfzone3=0.05d0*(xprobmax3-xprobmin3)
{do ix^DB=ixOmin^DB,ixOmax^DB\}
   disbd(1)=x(ix^D,1)-xprobmin1
   disbd(2)=xprobmax1-x(ix^D,1)
   disbd(3)=x(ix^D,2)-xprobmin2
   disbd(4)=xprobmax2-x(ix^D,2)
   disbd(5)=xprobmax3-x(ix^D,3)
   if(disbd(1)<bfzone1) then
     w(ix^D,v1_:v3_)=(1.d0-((bfzone1-disbd(1))/bfzone1)**2)*w(ix^D,v1_:v3_)
   endif
   if(disbd(2)<bfzone1) then
     w(ix^D,v1_:v3_)=(1.d0-((bfzone1-disbd(2))/bfzone1)**2)*w(ix^D,v1_:v3_)
   endif
   if(disbd(3)<bfzone2) then
     w(ix^D,v1_:v3_)=(1.d0-((bfzone2-disbd(3))/bfzone2)**2)*w(ix^D,v1_:v3_)
   endif
   if(disbd(4)<bfzone2) then
     w(ix^D,v1_:v3_)=(1.d0-((bfzone2-disbd(4))/bfzone2)**2)*w(ix^D,v1_:v3_)
   endif
   if(disbd(5)<bfzone3) then
     w(ix^D,v1_:v3_)=(1.d0-((bfzone3-disbd(5))/bfzone3)**2)*w(ix^D,v1_:v3_)
   endif
{end do\}
end subroutine frictional_velocity
!============================================================================= 
subroutine vhat(w,x,ixI^L,ixO^L,vhatmaxgrid)

! Calculate v_hat 

include 'amrvacdef.f'

integer, intent(in) :: ixI^L, ixO^L
double precision, intent(inout)  :: w(ixI^S,nw)
double precision, intent(in)  :: x(ixI^S,1:ndim)
double precision, intent(out) :: vhatmaxgrid

double precision              :: current(ixG^T,7-2*ndir:3),dxhm,tmp(ixG^T)
integer :: idirmin,idir,jdir,kdir
!-----------------------------------------------------------------------------

call getcurrent(w,ixI^L,ixO^L,idirmin,current)
w(ixI^S,v0_+1:v0_+ndir)=0.d0
! calculate Lorentz force
do idir=1,ndir; do jdir=1,ndir; do kdir=idirmin,3
   if(lvc(idir,jdir,kdir)/=0)then
      if(B0field) then
        tmp(ixO^S)=current(ixO^S,jdir)*w(ixO^S,b0_+kdir)+myB0_cell%w(ixO^S,kdir)
      else
        tmp(ixO^S)=current(ixO^S,jdir)*w(ixO^S,b0_+kdir)
      endif
      if(lvc(idir,jdir,kdir)==1)then
         w(ixO^S,v0_+idir)=w(ixO^S,v0_+idir)+tmp(ixO^S)
      else
         w(ixO^S,v0_+idir)=w(ixO^S,v0_+idir)-tmp(ixO^S)
      endif
   endif
enddo; enddo; enddo

if(B0field) then
  !tmp(ixO^S)=( ^C&(w(ixO^S,b^C_)+myB0%w(ixO^S,^C))**2+ )
  tmp(ixO^S)=dsqrt( ^C&(w(ixO^S,b^C_)+myB0%w(ixO^S,^C))**2+ )
else
  !tmp(ixO^S)=( ^C&w(ixO^S,b^C_)**2+ )
  tmp(ixO^S)=dsqrt( ^C&w(ixO^S,b^C_)**2+ )
endif

dxhm=dble(ndim)/(^D&1.0d0/dxlevel(^D)+)
^C&w(ixO^S,v^C_)=dxhm*w(ixO^S,v^C_)/tmp(ixO^S);
vhatmaxgrid=maxval(dsqrt( ^C&w(ixO^S,v^C_)**2+ ))

end subroutine vhat
!============================================================================
subroutine upwindLRmf(ixI^L,ixL^L,ixR^L,idims,w,wCT,wLC,wRC,x,dxdim)

! Determine the upwinded wLC(ixL) and wRC(ixR) from w. 
! the wCT is only used when PPM is exploited.

include 'amrvacdef.f'

integer, intent(in) :: ixI^L, ixL^L, ixR^L, idims
double precision, intent(in) :: dxdim
double precision, dimension(ixI^S,1:nw) :: w, wCT
double precision, dimension(ixG^T,1:nw) :: wLC, wRC
double precision, dimension(ixG^T,1:ndim) :: x

integer :: jxR^L, ixC^L, jxC^L, iw
double precision :: wLtmp(ixG^T,1:nw), wRtmp(ixG^T,1:nw)
double precision :: ldw(ixG^T), dwC(ixG^T)

character*79 :: savetypelimiter
!-----------------------------------------------------------------------------

jxR^L=ixR^L+kr(idims,^D);
ixCmax^D=jxRmax^D; ixCmin^D=ixLmin^D-kr(idims,^D);
jxC^L=ixC^L+kr(idims,^D);

do iw=b0_+1,b0_+ndir
  dwC(ixC^S)=w(jxC^S,iw)-w(ixC^S,iw)

  savetypelimiter=typelimiter
  if(savetypelimiter=='koren') typelimiter='korenL'
  if(savetypelimiter=='cada')  typelimiter='cadaL'
  if(savetypelimiter=='cada3') typelimiter='cada3L'
  call dwlimiter2(dwC,ixC^L,iw,idims,ldw,dxdim)

  wLtmp(ixL^S,iw)=wLC(ixL^S,iw)+half*ldw(ixL^S)
  if(savetypelimiter=='koren')then
    typelimiter='korenR'
    call dwlimiter2(dwC,ixC^L,iw,idims,ldw,dxdim)
  endif
  if(savetypelimiter=='cada')then
    typelimiter='cadaR'
    call dwlimiter2(dwC,ixC^L,iw,idims,ldw,dxdim)
  endif
  if(savetypelimiter=='cada3')then
    typelimiter='cada3R'
    call dwlimiter2(dwC,ixC^L,iw,idims,ldw,dxdim)
  endif
  wRtmp(ixR^S,iw)=wRC(ixR^S,iw)-half*ldw(jxR^S)
  typelimiter=savetypelimiter

end do
wLC(ixL^S,b1_:b3_)=wLtmp(ixL^S,b1_:b3_)
wRC(ixR^S,b1_:b3_)=wRtmp(ixR^S,b1_:b3_)

end subroutine upwindLRmf
!=============================================================================
subroutine tvdlfmf(qdt,ixI^L,ixO^L,idim^LIM, &
                     qtC,wCT,qt,wnew,wold,fC,dx^D,x)

! method=='tvdlf'  --> 2nd order TVD-Lax-Friedrich scheme.
! method=='tvdlf1' --> 1st order TVD-Lax-Friedrich scheme.

include 'amrvacdef.f'

double precision, intent(in)                         :: qdt, qtC, qt, dx^D
integer, intent(in)                                  :: ixI^L, ixO^L, idim^LIM
double precision, dimension(ixI^S,1:ndim), intent(in) ::  x
double precision, dimension(ixI^S,1:ndim)             ::  xi
double precision, dimension(ixI^S,1:nw)               :: wCT, wnew, wold
double precision, dimension(ixI^S,1:nwflux,1:ndim)        :: fC

double precision, dimension(ixG^T,1:nw) :: wLC, wRC
double precision, dimension(ixG^T)      :: fLC, fRC
double precision, dimension(ixG^T)      :: cmaxC
double precision :: dxinv(1:ndim),dxdim(1:ndim)
integer :: idims, iw, ix^L, hxO^L, ixC^L, ixCR^L, jxC^L, kxC^L, kxR^L
logical :: transport
logical, dimension(ixG^T) :: patchw
!-----------------------------------------------------------------------------

! The flux calculation contracts by one in the idim direction it is applied.
! The limiter contracts the same directions by one more, so expand ixO by 2.
ix^L=ixO^L;
do idims= idim^LIM
   ix^L=ix^L^LADD2*kr(idims,^D);
end do
if (ixI^L^LTix^L|.or.|.or.) &
   call mpistop("Error in tvdlfmf: Nonconforming input limits")

^D&dxinv(^D)=-qdt/dx^D;
^D&dxdim(^D)=dx^D;
fC=0.d0
do idims= idim^LIM
   if (B0field) then
      select case (idims)
      {case (^D)
         myB0 => myB0_face^D\}
      end select
   end if

   hxO^L=ixO^L-kr(idims,^D);
   ! ixC is centered index in the idim direction from ixOmin-1/2 to ixOmax+1/2
   ixCmax^D=ixOmax^D; ixCmin^D=hxOmin^D;

   ! Calculate wRC=uR_{j+1/2} and wLC=uL_j+1/2 
   jxC^L=ixC^L+kr(idims,^D);

   kxCmin^D=ixImin^D; kxCmax^D=ixImax^D-kr(idims,^D);
   kxR^L=kxC^L+kr(idims,^D);
   ixCR^L=ixC^L;
 
   wRC(kxC^S,1:nwflux)=wCT(kxR^S,1:nwflux)
   wLC(kxC^S,1:nwflux)=wCT(kxC^S,1:nwflux)

   ! Get interface positions:
   xi(kxC^S,1:ndim) = x(kxC^S,1:ndim)
   xi(kxC^S,idims) = half* ( x(kxR^S,idims)+x(kxC^S,idims) )

   call upwindLRmf(ixI^L,ixCR^L,ixCR^L,idims,wCT,wCT,wLC,wRC,x,dxdim(idims))

   ! For the high order Lax-Friedrich TVDLF scheme the limiter is based on
   ! the maximum eigenvalue, it is calculated in advance.
   ! determine mean state and store in wLC
   wLC(ixC^S,b1_:b3_)= &
         half*(wLC(ixC^S,b1_:b3_)+wRC(ixC^S,b1_:b3_))
   call getcmaxfff(wLC,xi,ixG^LL,ixC^L,idims,cmaxC)

   ! We regain wLC for further use
   wLC(ixC^S,b1_:b3_)=two*wLC(ixC^S,b1_:b3_)-wRC(ixC^S,b1_:b3_)

   ! Calculate fLC=f(uL_j+1/2) and fRC=f(uR_j+1/2) for each iw
   do iw=b0_+1,b0_+ndir
      call getfluxmf(wLC,xi,ixG^LL,ixC^L,iw,idims,fLC,transport)
      call getfluxmf(wRC,xi,ixG^LL,ixC^L,iw,idims,fRC,transport)
      if (transport) then
         fLC(ixC^S)=fLC(ixC^S)+wCT(ixC^S,v0_+idims)*wLC(ixC^S,iw)
         fRC(ixC^S)=fRC(ixC^S)+wCT(ixC^S,v0_+idims)*wRC(ixC^S,iw)
      end if
      ! To save memory we use fLC to store (F_L+F_R)/2=half*(fLC+fRC)
      fLC(ixC^S)=half*(fLC(ixC^S)+fRC(ixC^S))

      ! Add TVDLF dissipation to the flux
      ! To save memory we use fRC to store -cmax*half*(w_R-w_L)
      fRC(ixC^S)=-tvdlfeps*cmaxC(ixC^S)*half*(wRC(ixC^S,iw)-wLC(ixC^S,iw))
      ! fLC contains physical+dissipative fluxes
      fLC(ixC^S)=fLC(ixC^S)+fRC(ixC^S)

      if (slab) then
         fC(ixC^S,iw,idims)=dxinv(idims)*fLC(ixC^S)
         wnew(ixO^S,iw)=wnew(ixO^S,iw)+ &
              (fC(ixO^S,iw,idims)-fC(hxO^S,iw,idims))
      else
         select case (idims)
         {case (^D)
            fC(ixC^S,iw,^D)=-qdt*mygeo%surfaceC^D(ixC^S)*fLC(ixC^S)
            wnew(ixO^S,iw)=wnew(ixO^S,iw)+ &
              (fC(ixO^S,iw,^D)-fC(hxO^S,iw,^D))/mygeo%dvolume(ixO^S)\}
         end select
      end if

   end do ! Next iw
end do ! Next idims

if (.not.slab) call addgeometrymf(qdt,ixI^L,ixO^L,wCT,wnew,x)
! clean up divb
call divbclean_linde(ixI^L,ixO^L,wnew,x)

end subroutine tvdlfmf
!=============================================================================
subroutine evolve_centdiff4(qdt,ixI^L,ixO^L,wCT,w,fC,dx^D,x)

include 'amrvacdef.f'

integer, intent(in) :: ixI^L, ixO^L
double precision, intent(in) :: qdt, dx^D
double precision :: wCT(ixI^S,1:nw), w(ixI^S,1:nw)
double precision, intent(in) :: x(ixI^S,1:ndim)
double precision, dimension(ixI^S,1:ndim) ::  xi
double precision :: fC(ixI^S,1:nwflux,1:ndim)

double precision, dimension(ixG^T,1:nw) :: wLC, wRC
double precision, dimension(ixG^T)      :: vLC, vRC,cmaxLC,cmaxRC,f
double precision :: dxinv(1:ndim), dxdim(1:ndim)
integer :: idims, iw, idirmin,ix^D
integer :: ix^L, hxO^L, ixC^L, jxC^L, hxC^L, kxC^L, kkxC^L, kkxR^L
logical :: transport,patchw(ixG^T)
!-----------------------------------------------------------------------------
! two extra layers are needed in each direction for which fluxes are added.
ix^L=ixO^L;
do idims=1,ndim
   ix^L=ix^L^LADD2*kr(idims,^D);
end do

if (ixI^L^LTix^L|.or.|.or.) then
   call mpistop("Error in CentDiff4: Non-conforming input limits")
end if
^D&dxinv(^D)=-qdt/dx^D;
^D&dxdim(^D)=dx^D;

! Add fluxes to w
do idims=1,ndim
   if (B0field) then
      select case (idims)
      {case (^D)
         myB0 => myB0_face^D\}
      end select
   end if

   ix^L=ixO^L^LADD2*kr(idims,^D);
   hxO^L=ixO^L-kr(idims,^D);

   ixCmin^D=hxOmin^D; ixCmax^D=ixOmax^D;
   hxC^L=ixC^L-kr(idims,^D);
   jxC^L=ixC^L+kr(idims,^D);
   kxC^L=ixC^L+2*kr(idims,^D);

   kkxCmin^D=ixImin^D; kkxCmax^D=ixImax^D-kr(idims,^D);
   kkxR^L=kkxC^L+kr(idims,^D);
   wRC(kkxC^S,1:nwflux)=wCT(kkxR^S,1:nwflux)
   wLC(kkxC^S,1:nwflux)=wCT(kkxC^S,1:nwflux)

   ! Get interface positions:
   xi(kkxC^S,1:ndim) = x(kkxC^S,1:ndim)
   xi(kkxC^S,idims) = half* ( x(kkxR^S,idims)+x(kkxC^S,idims) )

   call upwindLR(ixI^L,ixC^L,ixC^L,idims,wCT,wCT,wLC,wRC,x,.false.,dxdim(idims))

   ! Calculate velocities from upwinded values
   call getcmaxfff(wLC,xi,ixG^LL,ixC^L,idims,cmaxLC)
   call getcmaxfff(wRC,xi,ixG^LL,ixC^L,idims,cmaxRC)
   ! now take the maximum of left and right states
   vLC(ixC^S)=max(cmaxRC(ixC^S),cmaxLC(ixC^S))

   do iw=b0_+1,b0_+ndir
      ! Get non-transported flux
      call getfluxmf(wCT,xi,ixI^L,ix^L,iw,idims,f,transport)
      ! Add transport flux
      if (transport) f(ix^S)=f(ix^S)+wCT(ix^S,v0_+idims)*wCT(ix^S,iw)
      ! Center flux to interface
      ! f_i+1/2= (-f_(i+2) +7 f_(i+1) + 7 f_i - f_(i-1))/12
      fC(ixC^S,iw,idims)=(-f(kxC^S)+7.0d0*(f(jxC^S)+f(ixC^S))-f(hxC^S))/12.0d0
      ! add rempel dissipative flux, only second order version for now
      fC(ixC^S,iw,idims)=fC(ixC^S,iw,idims)-half*vLC(ixC^S) &
                                     *(wRC(ixC^S,iw)-wLC(ixC^S,iw))

      if (slab) then
         fC(ixC^S,iw,idims)=dxinv(idims)*fC(ixC^S,iw,idims)
         ! result: f_(i+1/2)-f_(i-1/2) = [-f_(i+2)+8(f_(i+1)+f_(i-1))-f_(i-2)]/12
         w(ixO^S,iw)=w(ixO^S,iw)+(fC(ixO^S,iw,idims)-fC(hxO^S,iw,idims))
      else
         select case (idims)
         {case (^D)
            fC(ixC^S,iw,^D)=-qdt*mygeo%surfaceC^D(ixC^S)*fC(ixC^S,iw,^D)
            w(ixO^S,iw)=w(ixO^S,iw)+ &
                 (fC(ixO^S,iw,^D)-fC(hxO^S,iw,^D))/mygeo%dvolume(ixO^S)\}
         end select
      end if
   end do    !next iw
end do
if (.not.slab) call addgeometrymf(qdt,ixI^L,ixO^L,wCT,w,x)
! clean up divb
call divbclean_linde(ixI^L,ixO^L,w,x)

end subroutine evolve_centdiff4
!!=============================================================================
subroutine getdtfff_courant(w,x,ixI^L,ixO^L,dtnew)

! compute CFL limited dt (for variable time stepping)

include 'amrvacdef.f'

integer, intent(in) :: ixI^L, ixO^L
double precision, intent(in) :: x(ixI^S,1:ndim)
double precision, intent(inout) :: w(ixI^S,1:nw), dtnew

double precision :: courantmax, dxinv(1:ndim)
double precision :: cmax(ixG^T),tmp(ixG^T),alfven(ixG^T)
integer :: idims
!-----------------------------------------------------------------------------
dtnew=bigdouble
courantmax=zero
^D&dxinv(^D)=one/dxlevel(^D);

! calculate alfven speed assuming rho=1.d0
if(B0field) then
  alfven(ixO^S)=dsqrt((^C&(w(ixO^S,b^C_)+myB0%w(ixO^S,^C))**2+ )/w(ixO^S,rho_))
else
  alfven(ixO^S)=dsqrt((^C&w(ixO^S,b^C_)**2+ )/w(ixO^S,rho_))
endif

do idims=1,ndim
   cmax(ixO^S)=dabs(w(ixO^S,v0_+idims))+alfven(ixO^S)
   !cmax_mype = max(cmax_mype,maxval(cmax(ixO^S)))
   if (.not.slab) then
      tmp(ixO^S)=cmax(ixO^S)/mygeo%dx(ixO^S,idims)
      courantmax=max(courantmax,maxval(tmp(ixO^S)))
   else
      tmp(ixO^S)=cmax(ixO^S)*dxinv(idims)
      courantmax=max(courantmax,maxval(tmp(ixO^S)))
   end if
end do
! courantmax='max( c/dx)'
if (courantmax>smalldouble)  dtnew=min(dtnew,cmf_c/courantmax)

end subroutine getdtfff_courant
!=============================================================================
subroutine getcmaxfff(w,x,ixI^L,ixO^L,idims,cmax)
include 'amrvacdef.f'

logical :: new_cmax,needcmin
integer, intent(in) :: ixI^L, ixO^L, idims
double precision, intent(in)    :: x(ixI^S,1:ndim),w(ixI^S,1:nw)
double precision, intent(out) :: cmax(ixG^T)
!-----------------------------------------------------------------------------

! calculate alfven speed
if(B0field) then
  cmax(ixO^S)=dsqrt((^C&(w(ixO^S,b^C_)+myB0%w(ixO^S,^C))**2+ )/w(ixO^S,rho_))
else
  cmax(ixO^S)=dsqrt((^C&w(ixO^S,b^C_)**2+ )/w(ixO^S,rho_))
endif
cmax(ixO^S)=cmax(ixO^S)+dabs(w(ixO^S,v0_+idims))

end subroutine getcmaxfff
!=============================================================================
subroutine divbclean_linde(ixI^L,ixO^L,w,x)

! Add Linde's divB related sources to wnew within ixO
include 'amrvacdef.f'

integer, intent(in)             :: ixI^L, ixO^L
double precision, intent(in)    :: x(ixI^S,1:ndim)
double precision, intent(inout) :: w(ixI^S,1:nw)
integer :: idims, ix^L
double precision :: divb(ixG^T),graddivb(ixG^T),bdivb(ixG^T,1:ndir)
!-----------------------------------------------------------------------------

! Calculate div B
ix^L=ixO^L^LADD1;
call getdivb(w,ixI^L,ix^L,divb)

! Add Linde's diffusive terms
do idims=1,ndim
   ! Calculate grad_idim(divb)
   select case(typegrad)
   case("central")
     call gradient(divb,ixO^L,idims,graddivb)
   case("limited")
     call gradientS(divb,ixO^L,idims,graddivb)
   end select

   ! Multiply by Linde's eta*dt = divbdiff*(c_max*dx)*dt = divbdiff*dx**2
   if (slab) then
      graddivb(ixO^S)=graddivb(ixO^S)*cmf_divb/(^D&1.0d0/dxlevel(^D)**2+)
   else
      graddivb(ixO^S)=graddivb(ixO^S)*cmf_divb &
                      /(^D&1.0d0/mygeo%dx(ixO^S,^D)**2+)
   end if
   ! B_idim += eta*grad_idim(divb)
   w(ixO^S,b0_+idims)=w(ixO^S,b0_+idims)+graddivb(ixO^S)
end do

end subroutine divbclean_linde
!============================================================================= 
subroutine addgeometrymf(qdt,ixI^L,ixO^L,wCT,w,x)

! Add geometrical source terms to w

include 'amrvacdef.f'

integer, intent(in)             :: ixI^L, ixO^L
double precision, intent(in)    :: qdt, x(ixI^S,1:ndim)
double precision, intent(inout) :: wCT(ixI^S,1:nw), w(ixI^S,1:nw)
!.. local ..
double precision :: tmp(ixG^T)
integer          :: iw
!-----------------------------------------------------------------------------

select case (typeaxial)
case ('slab')
   ! No source terms in slab symmetry
case ('cylindrical')
{^IFPHI
     ! s[Bphi]=(Bphi*vr-Br*vphi)/radius
     tmp(ixO^S)=(wCT(ixO^S,bphi_)*wCT(ixO^S,v1_) &
                -wCT(ixO^S,br_)*wCT(ixO^S,v3_))
     w(ixO^S,bphi_)=w(ixO^S,bphi_)+qdt*tmp(ixO^S)/x(ixO^S,1)
}
case ('spherical')
   do iw=1,nwflux
      select case (iw)
{^NOONEC
      ! s[b2]=(vr*Btheta-vtheta*Br)/r
      !       + cot(theta)*psi/r
      case (b2_)
         tmp(ixO^S)= wCT(ixO^S,v1_)*wCT(ixO^S,b2_) &
                    -wCT(ixO^S,v2_)*wCT(ixO^S,b1_)
         if (B0field) then
            tmp(ixO^S)=tmp(ixO^S)+wCT(ixO^S,v1_)*myB0_cell%w(ixO^S,2) &
                       -wCT(ixO^S,v2_)*myB0_cell%w(ixO^S,1)
         end if
         ! Divide by radius and add to w
         w(ixO^S,iw)=w(ixO^S,iw)+qdt*tmp(ixO^S)/x(ixO^S,1)
}
{^IFTHREEC
      ! s[b3]=(vr*Bphi-vphi*Br)/r
      !       -cot(theta)*(vphi*Btheta-vtheta*Bphi)/r
      case (b3_)
         tmp(ixO^S)=wCT(ixO^S,v1_)*wCT(ixO^S,b3_) &
                 -wCT(ixO^S,v3_)*wCT(ixO^S,b1_){^NOONED &
                -(wCT(ixO^S,v3_)*wCT(ixO^S,b2_) &
                 -wCT(ixO^S,v2_)*wCT(ixO^S,b3_))*dcos(x(ixO^S,2)) &
                               /dsin(x(ixO^S,2)) }
         if (B0field) then
            tmp(ixO^S)=tmp(ixO^S)+wCT(ixO^S,v1_)*myB0_cell%w(ixO^S,3) &
               -wCT(ixO^S,v3_)*myB0_cell%w(ixO^S,1){^NOONED &
               -(wCT(ixO^S,v3_)*myB0_cell%w(ixO^S,2) &
                -wCT(ixO^S,v2_)*myB0_cell%w(ixO^S,3))*dcos(x(ixO^S,2)) &
                               /dsin(x(ixO^S,2)) }
         end if
         ! Divide by radius and add to w
         w(ixO^S,iw)=w(ixO^S,iw)+qdt*tmp(ixO^S)/x(ixO^S,1)
}
      end select
   end do
end select

end subroutine addgeometrymf
!=============================================================================