class AccountingPeriods < Application
  # provides :xml, :yaml, :js

  def index
    @accounting_periods = AccountingPeriod.all.sort
    display @accounting_periods, :layout => layout?
  end

  def show(id)
    @accounting_period = AccountingPeriod.get(id)
    raise NotFound unless @accounting_period
    display @accounting_period
  end

  def period_balances(id)
    @accounting_period = AccountingPeriod.get(id)
    raise NotFound unless @accounting_period
    display @accounting_period
  end

  def new
    only_provides :html
    @accounting_period = AccountingPeriod.new
    display @accounting_period, :layout => layout?
  end

  def edit(id)
    only_provides :html
    @accounting_period = AccountingPeriod.get(id)
    raise NotFound unless @accounting_period
    display @accounting_period
  end

  def create(accounting_period)
    @accounting_period = AccountingPeriod.new(accounting_period)
    if @accounting_period.save
      redirect resource(:accounts), :message => {:notice => "AccountingPeriod was successfully created"}
    else
      message[:error] = "AccountingPeriod failed to be created"
      render :new
    end
  end

  def update(id, accounting_period)
    @accounting_period = AccountingPeriod.get(id)
    raise NotFound unless @accounting_period
    if @accounting_period.update(accounting_period)
       redirect resource(:accounts)
    else
      display @accounting_period, :edit
    end
  end

end # AccountingPeriods
