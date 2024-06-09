#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'octokit'
  gem 'csv'
  gem 'dotenv'
  gem 'gruff'
  gem 'business_time'
end

require 'octokit'
require 'csv'
require 'dotenv/load'
require 'gruff'
require 'business_time'

BusinessTime::Config.beginning_of_workday = "10:00 am"
BusinessTime::Config.end_of_workday = "07:00 pm"
BusinessTime::Config.work_week = [:mon, :tue, :wed, :thu, :fri]

class PullRequestResult
  attr_accessor :number, :title, :author, :created_at, :review_requested_at,
                :opened_at, :first_comment_at, :approved_at, :merged_at, :merge_commit_sha

  def initialize(pr, events, reviews, comments)
    @number = pr.number
    @title = pr.title
    @author = pr.user.login
    @created_at = pr.created_at
    @opened_at = pr.created_at
    @review_requested_at = nil
    @first_comment_at = nil
    @approved_at = nil
    @merged_at = pr.merged_at
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

  private

  def calculate_by_events(events)
    events.each do |event|
      @review_requested_at ||= event.created_at if event.event == 'review_requested'
      @merged_at = event.created_at if event.commit_id == @merge_commit_sha && event.event == 'closed'
    end
  end

  def calculate_by_comments(comments)
    comments.each do |comment|
      if comment.user.login == author
        next
      end
      @first_comment_at ||= comment.created_at
      @first_comment_at = comment.created_at if @first_comment_at > comment.created_at
    end
  end

  def calculate_by_reviews(reviews)
    reviews.each do |review|
      @approved_at ||= review.submitted_at if review.state == 'APPROVED'
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
    end
  end

  def create_result(pr)
    events = @client.issue_events(@repo, pr.number)
    reviews = @client.pull_request_reviews(@repo, pr.number)
    comments = @client.issue_comments(@repo, pr.number)
    PullRequestResult.new(pr, events, reviews, comments)
  end

  def execute!
    results = fetch_results

    CSVWriter.new(results).execute!
    GraphGenerator.new(results).execute!
  end
end

class CSVWriter
  def initialize(pr_results)
    @pr_results = pr_results
  end

  def execute!(filename = "pr_data.csv")
    CSV.open(filename, "w") do |csv|
      csv << %w["PR番号" "タイトル" "作成時刻" "レビュー依頼時刻" "Open時刻" "最初のコメント時刻" "approve時刻" "merge時刻" "レビュー依頼からapproveまでの時間(時間)"]

      @pr_results.each do |result_data|
        csv << [
          result_data.number,
          result_data.title,
          result_data.created_at,
          result_data.review_requested_at,
          result_data.opened_at,
          result_data.first_comment_at,
          result_data.approved_at,
          result_data.merged_at,
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

  def execute!
    weekly_data = Hash.new { |hash, key| hash[key] = [] }

    @pr_results.each do |pr|
      next unless pr.review_requested_at && pr.approved_at

      week = pr.review_requested_at.strftime('%Y-%U')
      weekly_data[week] << pr.review_to_approve_time
    end

    weekly_avg = weekly_data.map { |week, times| [week, times.sum / times.size] }.to_h

    g = Gruff::Line.new
    g.title = 'Average Review Request to Approval Time per Week'
    g.labels = weekly_avg.each_with_index.map { |(week, _), i| [i, week] }.to_h
    g.data(:'Average Time (hours)', weekly_avg.values)
    g.write('review_to_approve_time.png')

    puts "グラフを作成しました: review_to_approve_time.png"
  end
end

# 実行
from_date = '2024-05-01'
to_date = '2024-06-30'

checker = ReviewChecker.new(from_date, to_date)
checker.execute!
