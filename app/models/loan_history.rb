class LoanHistory
  include DataMapper::Resource
  
#   property :id,                        Serial  # composite key transperantly enables history-rewriting
  property :loan_id,                   Integer, :key => true
  property :date,                      Date,    :key => true  # the day that this record applies to
  property :created_at,                DateTime  # automatic, nice for benchmarking runs
  property :run_number,                Integer, :nullable => false, :default => 0
  property :current,                   Boolean  # tracks the row refering to the loans current status. we can query for these
                                                # during reporting. I put it here to save an extra write to the db during 
                                                # update_history_now

  property :amount_in_default,          Integer # less normalisation = faster queries
  property :days_overdue,               Integer
  property :week_id,                    Integer # good for aggregating.

  # some properties for similarly named methods of a loan:
  property :scheduled_outstanding_total,     Integer, :nullable => false, :index => true
  property :scheduled_outstanding_principal, Integer, :nullable => false, :index => true
  property :actual_outstanding_total,        Integer, :nullable => false, :index => true
  property :actual_outstanding_principal,    Integer, :nullable => false, :index => true
  property :principal_due,                  Integer, :nullable => false, :index => true
  property :interest_due,                  Integer, :nullable => false, :index => true
  property :principal_paid,                  Integer, :nullable => false, :index => true
  property :interest_paid,                  Integer, :nullable => false, :index => true

  property :status,                          Enum.send('[]', *STATUSES)

  belongs_to :loan#, :index => true
  belongs_to :client, :index => true         # speed up reports
  belongs_to :client_group, :index => true, :nullable => true   # by avoiding 
  belongs_to :center, :index => true         # lots of joins!
  belongs_to :branch, :index => true         # muahahahahahaha!
  
  validates_present :loan,:scheduled_outstanding_principal,:scheduled_outstanding_total,:actual_outstanding_principal,:actual_outstanding_total


  # __DEPRECATED__ the prefered way to make history and future.
  # HISTORY IS NOW WRITTEN BY THE LOAN MODEL USING update_history_bulk_insert
  def self.add_group
    clients={}
    LoanHistory.all.each{|lh|
      next if lh.client_group_id or not lh.client_id # what happens if group is changed?
      
      clients[lh.client_id] = clients.key?(lh.client_id) ? clients[lh.client_id] : Client.get(lh.client_id)
      
      if clients[lh.client_id]
        lh.client_group_id = clients[lh.client_id].client_group_id
        if not lh.save
          lh.errors
        end
      end
    }
    puts "Done"
  end

  
  # __DEPRECATED__ the prefered way to make history and future.
  # HISTORY IS NOW WRITTEN BY THE LOAN MODEL USING update_history_bulk_insert

  def self.write_for(loan, date)
    if result = LoanHistory::create(
      :loan_id =>                           loan.id,
      :date =>                              date,
      :status =>                            loan.get_status(date),
      :scheduled_outstanding_principal =>   loan.scheduled_outstanding_principal_on(date),
      :scheduled_outstanding_total =>       loan.scheduled_outstanding_total_on(date),
      :actual_outstanding_principal =>      loan.actual_outstanding_principal_on(date),
      :actual_outstanding_total =>          loan.actual_outstanding_total_on(date) )
      return result
    else
      Merb.logger.error! "Could not create a LoanHistory record, validations maybe?"
      Merb.logger.error! "errors object: #{result.errors.inspect}"
      return result
    end
  end

  # TODO should be private method?
  def self.make_insert_for(loan, date)
    history = history_for(date)
    %Q{(#{history.id}, '#{date}', #{status}, #{history.scheduled_outstanding_principal_on(date)}, #{history.scheduled_outstanding_total_on(date)}, #{history.actual_outstanding_principal_on(date)},#{history.actual_outstanding_total_on(date)})}
  end

  def self.sum_outstanding_for(date, loan_ids)
    repository.adapter.query(%Q{
      SELECT
        SUM(scheduled_outstanding_principal) AS scheduled_outstanding_principal,
        SUM(scheduled_outstanding_total)     AS scheduled_outstanding_total,
        SUM(actual_outstanding_principal)    AS actual_outstanding_principal,
        SUM(actual_outstanding_total)        AS actual_outstanding_total
      FROM
      (select scheduled_outstanding_principal,scheduled_outstanding_total, actual_outstanding_principal, actual_outstanding_total from
        (select loan_id, max(date) as date from loan_history where date <= '#{date.strftime('%Y-%m-%d')}' and loan_id in (#{loan_ids.join(', ')}) and status in (5,6) group by loan_id) as dt, 
        loan_history lh 
      where lh.loan_id = dt.loan_id and lh.date = dt.date) as dt1;})
  end

  def self.defaulted_loan_info (days = 7, date = Date.today, query ={})
    # this does not work as expected if the loan is repaid and goes back into default within the days we are looking at it.
    defaulted_loan_ids = repository.adapter.query(%Q{
      SELECT loan_id FROM
        (SELECT loan_id, max(ddiff) as diff 
         FROM (SELECT date, loan_id, datediff(now(),date) as ddiff,actual_outstanding_principal - scheduled_outstanding_principal as diff 
               FROM loan_history 
               WHERE actual_outstanding_principal != scheduled_outstanding_principal and date < now()) as dt group by loan_id having diff < #{days}) as dt1;})
  end

  def self.defaulted_loan_info_by_branch(branch_id, date = Date.today, query ={})
    # this does not work as expected if the loan is repaid and goes back into default within the days we are looking at it.
    repository.adapter.query(%Q{
         SELECT sum(pdiff) principal, sum(tdiff) total FROM
         (SELECT actual_outstanding_principal - scheduled_outstanding_principal as pdiff, 
                actual_outstanding_total - scheduled_outstanding_total as tdiff
         FROM loan_history 
         WHERE actual_outstanding_principal != scheduled_outstanding_principal 
         AND branch_id=#{branch_id} AND current=1
         AND date <= '#{date.strftime("%Y-%m-%d")}') as dt WHERE pdiff>0 AND tdiff>0;})
  end
  
  def self.defaulted_loan_info_for(obj, date=Date.today, type=:aggregate)
    if obj.class==Branch
      query = "branch_id=#{obj.id}"
    elsif obj.class==Center
      query = "center_id=#{obj.id}"
    elsif obj.class==ClientGroup
      query = "client_group_id=#{obj.id}"
    end
    
    # either we list or we aggregate depending on type
    if type==:listing
      select = %Q{
                   loan_id, branch_id, center_id, client_group_id, client_id, amount_in_default, days_overdue as late_by, 
                   actual_outstanding_total-scheduled_outstanding_total total_due, actual_outstanding_principal-scheduled_outstanding_principal principal_due
               };
    else
      select = %Q{
                   SUM(actual_outstanding_total-scheduled_outstanding_total) total_due, SUM(actual_outstanding_principal-scheduled_outstanding_principal) principal_due
               };
    end
      
    # these are the loan history lines which represent the last line before @date
    rows = repository.adapter.query(%Q{
      SELECT loan_id,max(date)
      FROM loan_history
      WHERE date < '#{date.strftime("%Y-%m-%d")}' and amount_in_default > 0 and status in (5,6) and #{query}
      GROUP BY loan_id})
    return nil if rows and rows.length==0

    # These are the lines from the loan history
    query = %Q{
      SELECT #{select}
      FROM loan_history
      WHERE (loan_id,date) IN (#{rows.map{|x| "(#{x[0]}, '#{x[1].strftime("%Y-%m-%d")}')"}.join(',')})
      ORDER BY branch_id, center_id}
    repository.adapter.query(query).first
  end


  def self.sum_outstanding_by_group(from_date, to_date)
    ids=repository.adapter.query("SELECT loan_id, max(date) date FROM loan_history 
                                  WHERE status in (5,6) AND date>='#{from_date.strftime('%Y-%m-%d')}' AND date<='#{to_date.strftime('%Y-%m-%d')}' GROUP BY loan_id"
                                 ).collect{|x| "(#{x.loan_id}, '#{x.date.strftime('%Y-%m-%d')}')"}.join(",")
    return false if ids.length==0
    repository.adapter.query(%Q{
      SELECT 
        SUM(scheduled_outstanding_principal) AS scheduled_outstanding_principal,
        SUM(scheduled_outstanding_total)     AS scheduled_outstanding_total,
        SUM(actual_outstanding_principal)    AS actual_outstanding_principal,
        SUM(actual_outstanding_total)        AS actual_outstanding_total,
        SUM(if(actual_outstanding_principal<scheduled_outstanding_principal,  scheduled_outstanding_principal-actual_outstanding_principal,0)) AS advance_principal,
        SUM(if(actual_outstanding_total<scheduled_outstanding_total,          scheduled_outstanding_total-actual_outstanding_total,0))         AS advance_total,
        client_group_id,
        center_id
      FROM loan_history
      WHERE (loan_id, date) in (#{ids}) 
      GROUP BY client_group_id;
    })
  end


  def self.sum_outstanding_for(obj, from_date=Date.today-7, to_date=Date.today)
    q = "#{obj.class.name.snake_case}_id"
    repository.adapter.query(%Q{
      SELECT
        SUM(scheduled_outstanding_principal) AS scheduled_outstanding_principal,
        SUM(scheduled_outstanding_total)     AS scheduled_outstanding_total,
        SUM(if(actual_outstanding_principal>0, actual_outstanding_principal,0))    AS actual_outstanding_principal,
        SUM(if(actual_outstanding_total>0,     actual_outstanding_total, 0))        AS actual_outstanding_total,
        SUM(if(actual_outstanding_principal<0, actual_outstanding_principal,0))    AS advance_principal,
        SUM(if(actual_outstanding_total<0,     actual_outstanding_total,0))        AS advacne_total,
        COUNT(DISTINCT(loan_id))             AS loans_count,
        COUNT(DISTINCT(client_id))           AS clients_count,
        branch_id
      FROM loan_history
      WHERE #{q}=#{obj.id} AND current=1 AND date>='#{from_date.strftime('%Y-%m-%d')}' AND date<='#{to_date.strftime('%Y-%m-%d')}' AND status in (5,6)
      GROUP BY #{q}
    })
  end

  def self.amount_disbursed_for(obj, from_date, to_date)
    query = if obj.class==Branch
              %Q{
                 SELECT sum(l.amount) amount, COUNT(l.id)
                 FROM branches b, centers c, clients cl, loans l 
                 WHERE b.id=#{obj.id} and c.branch_id=b.id and cl.center_id=c.id and l.client_id=cl.id and l.disbursal_date is not null and l.deleted_at is null
                       and l.disbursal_date<='#{to_date.strftime('%Y-%m-%d')}' and l.disbursal_date>='#{from_date.strftime('%Y-%m-%d')}'
               }
            elsif obj.class==Center
              %Q{
                 SELECT sum(l.amount) amount, COUNT(l.id)
                 FROM   centers c, clients cl, loans l 
                 WHERE  c.id=#{obj.id} and cl.center_id=c.id and l.client_id=cl.id and l.disbursal_date is not null and l.deleted_at is null
                        and l.disbursal_date<='#{to_date.strftime('%Y-%m-%d')}' and l.disbursal_date>='#{from_date.strftime('%Y-%m-%d')}'
               }
            elsif obj.class==ClientGroup
              %Q{
                 SELECT sum(l.amount) amount, COUNT(l.id)
                 FROM   client_groups cg, clients cl, loans l 
                 WHERE  cg.id=#{obj.id} and cl.client_group_id=cg.id and l.client_id=cl.id and l.disbursal_date is not null and l.deleted_at is null
                        and l.disbursal_date<='#{to_date.strftime('%Y-%m-%d')}' and l.disbursal_date>='#{from_date.strftime('%Y-%m-%d')}'
               }
            end
    repository.adapter.query(query).first
  end
end
