# frozen_string_literal: true

require 'octokit'
require 'csv'
require 'dotenv/load'
require 'gruff'
require 'business_time'

BusinessTime::Config.beginning_of_workday = "10:00 am"
BusinessTime::Config.end_of_workday = "20:00 pm"
BusinessTime::Config.work_week = [:mon, :tue, :wed, :thu, :fri]

class PullRequestResult
  attr_accessor :number, :title, :author, :created_at, :review_requested_at,
                :opened_at, :approved_at, :merged_at, :merge_commit_sha

  def initialize(pr, events, reviews, comments)
    @number = pr.number
    @title = pr.title
    @author = pr.user.login
    @created_at = pr.created_at.in_time_zone('Tokyo')
    @opened_at = pr.created_at.in_time_zone('Tokyo')
    @review_requested_at = nil
    @first_comment_at = nil
    @approved_at = nil
    @merged_at = nil
    @merge_commit_sha = pr.merge_commit_sha

    calculate_by_events(events)
    calculate_by_comments(comments)
    calculate_by_reviews(reviews)
  end

  def review_to_approve_time
    return nil unless @review_requested_at && @approved_at

    business_hours = @review_requested_at.business_time_until(@approved_at)
    (business_hours / 3600).round(2) # 時間単位に変換
  end

  def review_to_first_comment_time
    return nil unless @review_requested_at && first_comment_or_approve_at

    business_hours = @review_requested_at.business_time_until(first_comment_or_approve_at)
    (business_hours / 3600).round(2) # 時間単位に変換
  end

  def first_comment_or_approve_at
    return @first_comment_at if @first_comment_at
    @approved_at
  end

  private

  def calculate_by_events(events)
    events.each do |event|
      @review_requested_at ||= event.created_at.in_time_zone('Tokyo') if event.event == 'review_requested'
      @merged_at = event.created_at.in_time_zone('Tokyo') if event.commit_id == @merge_commit_sha && event.event == 'closed'
    end
  end

  def calculate_by_comments(comments)
    comments.each do |comment|
      if comment.user.login == author
        next
      end
      comment_created_at = comment.created_at.in_time_zone('Tokyo')
      @first_comment_at ||= comment_created_at
      @first_comment_at = comment_created_at if @first_comment_at >comment_created_at
    end
  end

  def calculate_by_reviews(reviews)
    reviews.each do |review|
      @approved_at ||= review.submitted_at.in_time_zone('Tokyo') if review.state == 'APPROVED'
    end
  end
end

class ReviewChecker
  def initialize(from_date, to_date)
    @client = Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN'])
    @repo = ENV['REPOSITORY']
    @users = ENV['USERS'].split(',')  # 複数ユーザをカンマ区切りで環境変数に設定
    @from_date = from_date
    @to_date = to_date
  end

  def fetch_results
    prs = []
    @users.each do |user|
      query = "repo:#{@repo} author:#{user} created:#{@from_date}..#{@to_date} is:pr is:merged review:approved"
      page = 1

      loop do
        response = @client.search_issues(query, { per_page: 50, page: page })
        break if response.items.empty?

        prs.concat(response.items)
        page += 1
      end
    end

    prs.sort_by! { |pr| pr.created_at }
    prs.map do |pr|
      create_result(pr)
    end.select { |pr| !pr.review_requested_at.blank? }
  end

  def create_result(pr)
    events = @client.issue_events(@repo, pr.number)
    reviews = @client.pull_request_reviews(@repo, pr.number)
    comments =  @client.issue_comments(@repo, pr.number)
    PullRequestResult.new(pr, events, reviews, comments)
  end

  def execute!
    results = fetch_results

    CSVWriter.new(results).execute!
    GraphGenerator.new(results).execute_line!
  end
end

class CSVWriter
  def initialize(pr_results)
    @pr_results = pr_results
  end

  def execute!(filename="pr_data.csv")
    CSV.open(filename, "w") do |csv|
      csv << %w[PR番号, タイトル, 作成時刻, レビュー依頼時刻, Open時刻, 最初のコメント時刻, approve時刻, merge時刻, レビュー依頼からコメントまでの時間, レビュー依頼からapproveまでの時間]

      @pr_results.each do |result_data|
        csv << [
          result_data.number,
          result_data.title,
          result_data.created_at,
          result_data.review_requested_at,
          result_data.opened_at,
          result_data.first_comment_or_approve_at,
          result_data.approved_at,
          result_data.merged_at,
          result_data.review_to_first_comment_time,
          result_data.review_to_approve_time
        ]
      end
    end

    puts "CSVファイルにPRデータを出力しました。"
  end
end

class GraphGenerator
  def initialize(pr_results)
    @pr_results = pr_results
  end

  def execute_line!
    weekly_approval_data = Hash.new { |hash, key| hash[key] = [] }
    weekly_first_comment_data = Hash.new { |hash, key| hash[key] = [] }

    @pr_results.each do |pr|
      next unless pr.review_requested_at && pr.approved_at

      week = pr.review_requested_at.strftime('%Y-%U')
      weekly_approval_data[week] << pr.review_to_approve_time
      weekly_first_comment_data[week] << pr.review_to_first_comment_time
    end

    weekly_approval_avg = weekly_approval_data.map do |week, times|
      times.compact!
      [week, times.empty? ? 0 : times.sum / times.size]
    end.to_h

    weekly_approval_median = weekly_approval_data.map do |week, times|
      times.compact!
      [week, times.empty? ? 0 : median(times)]
    end.to_h

    weekly_first_comment_avg = weekly_first_comment_data.map do |week, times|
      times.compact!
      [week, times.empty? ? 0 : times.sum / times.size]
    end.to_h

    weekly_first_comment_median = weekly_first_comment_data.map do |week, times|
      times.compact!
      [week, times.empty? ? 0 : median(times)]
    end.to_h

    all_weeks = (weekly_approval_avg.keys + weekly_first_comment_avg.keys).uniq.sort

    g = Gruff::Line.new
    g.title = 'Average and 50%ile Review Request to Approval and First Comment Time per Week'
    g.labels = all_weeks.each_with_index.map { |week, i| [i, week] }.to_h

    g.data(:'Average Approval', all_weeks.map { |week| weekly_approval_avg[week] || 0 })
    g.data(:'Average First Comment', all_weeks.map { |week| weekly_first_comment_avg[week] || 0 })

    g.data(:'50%ile Approval', all_weeks.map { |week| weekly_approval_median[week] || 0 })
    g.data(:'50%ile First Comment', all_weeks.map { |week| weekly_first_comment_median[week] || 0 })
    g.write('review_to_approve_time.png')

    puts "グラフを作成しました: review_to_approve_time.png"
  end

  private

  def median(array)
    sorted = array.sort
    len = sorted.length
    (sorted[(len - 1) / 2] + sorted[len / 2]) / 2.0
  end

end

# 実行
from_date = '2024-05-01'
to_date = '2024-06-30'   

checker = ReviewChecker.new(from_date,to_date)
checker.execute!

