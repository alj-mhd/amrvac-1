module mod_hall
  use mod_hall_phys
  use mod_hall_hllc
  use mod_hall_roe
  use mod_hall_ppm

  use mod_amrvac

  implicit none
  public

contains

  subroutine hall_activate()
    call hall_phys_init()
    call hall_hllc_init()
    call hall_roe_init()
    call hall_ppm_init()
  end subroutine hall_activate

end module mod_hall
