module TransactionService::Process
  Gateway = TransactionService::Gateway
  Worker = TransactionService::Worker
  ProcessStatus = TransactionService::DataTypes::ProcessStatus

  class Preauthorize

    TxStore = TransactionService::Store::Transaction

    def create(tx:, gateway_fields:, gateway_adapter:, force_sync:)
      TransactionService::StateMachine.transition_to(tx.id, :initiated)
      tx.current_state = :initiated

      if !force_sync
        proc_token = Worker.enqueue_preauthorize_op(
          community_id: tx.community_id,
          transaction_id: tx.id,
          op_name: :do_create,
          op_input: [tx, gateway_fields])

        proc_status_response(proc_token)
      else
        do_create(tx, gateway_fields)
      end
    end

    def do_create(tx, gateway_fields)
      gateway_adapter = TransactionService::Transaction.gateway_adapter(tx.payment_gateway)

      completion = gateway_adapter.create_payment(
        tx: tx,
        gateway_fields: gateway_fields,
        force_sync: true)

      if completion[:success] && completion[:sync]
        finalize_res = finalize_create(tx: tx, gateway_adapter: gateway_adapter, force_sync: true)
      elsif !completion[:success]
        delete_failed_transaction(tx)
      end
      if finalize_res.success
        completion[:response]
      else
        delete_failed_transaction(tx)
        finalize_res
      end
    end

    def finalize_create(tx:, gateway_adapter:, force_sync:)
      ensure_can_execute!(tx: tx, allowed_states: [:initiated, :preauthorized])

      if !force_sync
        proc_token = Worker.enqueue_preauthorize_op(
          community_id: tx.community_id,
          transaction_id: tx.id,
          op_name: :do_finalize_create,
          op_input: [tx.id, tx.community_id])

        proc_status_response(proc_token)
      else
        do_finalize_create(tx.id, tx.community_id)
      end
    end

    def do_finalize_create(transaction_id, community_id)
      tx = TxStore.get_in_community(community_id: community_id, transaction_id: transaction_id)
      gateway_adapter = TransactionService::Transaction.gateway_adapter(tx.payment_gateway)

      res =
        if tx.current_state == :preauthorized
          Result::Success.new()
        else
          booking_res =
            if tx.availability.to_sym == :booking && !tx.booking.valid?
              void_payment(gateway_adapter, tx)
              Result::Error.new(TransactionService::Transaction::BookingDatesInvalid.new(I18n.t("error_messages.booking.double_booking_payment_voided")))
            elsif tx.availability.to_sym == :booking && tx.booking.per_hour?
              Result::Success.new()
            elsif tx.availability.to_sym == :booking
              initiate_booking(tx: tx).on_error { |error_msg, data|
                logger.error("Failed to initiate booking #{data.inspect} #{error_msg}", :failed_initiate_booking, tx.slice(:community_id, :id).merge(error_msg: error_msg))

                void_payment(gateway_adapter, tx)
              }.on_success { |data|
                response_body = data[:body]
                booking = response_body[:data]

                TxStore.update_booking_uuid(
                  community_id: tx.community_id,
                  transaction_id: tx.id,
                  booking_uuid: booking[:id]
                )
              }
            else
              Result::Success.new()
            end

          booking_res.on_success {
            if tx.stripe_payments.last.try(:intent_requires_action?)
              TransactionService::StateMachine.transition_to(tx.id, :payment_intent_requires_action)
            else
              TransactionService::StateMachine.transition_to(tx.id, :preauthorized)
            end
          }
        end

      res.and_then {
        Result::Success.new(TransactionService::Transaction.create_transaction_response(tx))
      }
    end

    def void_payment(gateway_adapter, tx)
      void_res = gateway_adapter.reject_payment(tx: tx, reason: "")[:response]

      void_res.on_success {
        logger.info("Payment voided after failed transaction", :void_payment, tx.slice(:community_id, :id))
      }.on_error { |payment_error_msg, payment_data|
        logger.error("Failed to void payment after failed booking", :failed_void_payment, tx.slice(:community_id, :id).merge(error_msg: payment_error_msg))
      }
      void_res
    end

    def reject(tx:, message:, sender_id:, gateway_adapter:)
      res = Gateway.unwrap_completion(
        gateway_adapter.reject_payment(tx: tx, reason: "")) do

        TransactionService::StateMachine.transition_to(tx.id, :rejected)
      end

      if res[:success] && message.present?
        send_message(tx, message, sender_id)
      end

      res
    end

    def complete_preauthorization(tx:, message:, sender_id:, gateway_adapter:)
      res = Gateway.unwrap_completion(
        gateway_adapter.complete_preauthorization(tx: tx)) do

        TransactionService::StateMachine.transition_to(tx.id, :paid)
      end

      if res[:success] && message.present?
        send_message(tx, message, sender_id)
      end

      res
    end

    def complete(tx:, message:, sender_id:, gateway_adapter:, metadata: {})
      TransactionService::StateMachine.transition_to(tx.id, :confirmed, metadata)
      TxStore.mark_as_unseen_by_other(community_id: tx.community_id,
                                      transaction_id: tx.id,
                                      person_id: tx.listing_author_id)

      if message.present?
        send_message(tx, message, sender_id)
      end

      Result::Success.new({result: true})
    end

    def cancel(tx:, message:, sender_id:, gateway_adapter:, metadata: {})
      TransactionService::StateMachine.transition_to(tx.id, :disputed, metadata)
      TxStore.mark_as_unseen_by_other(community_id: tx.community_id,
                                      transaction_id: tx.id,
                                      person_id: tx.listing_author_id)

      if message.present?
        send_message(tx, message, sender_id)
      end

      Result::Success.new({result: true})
    end

    # Stripe gateway works in sync mode. Failed transaction will be deleted.
    def delete_failed_transaction(tx)
      if tx.payment_gateway == :stripe
        TransactionService::Store::Transaction.delete(community_id: tx.community_id, transaction_id: tx.id)
      end
    end

    private

    def initiate_booking(tx:)
      community_uuid = UUIDUtils.parse_raw(tx.community_uuid)
      starter_uuid = UUIDUtils.parse_raw(tx.starter_uuid)
      listing_uuid = UUIDUtils.parse_raw(tx.listing_uuid)

      auth_context = {
        marketplace_id: community_uuid,
        actor_id: starter_uuid
      }

      HarmonyClient.post(
        :initiate_booking,
        body: {
          marketplaceId: community_uuid,
          refId: listing_uuid,
          customerId: starter_uuid,
          initialStatus: :paid,
          start: tx.booking.start_on,
          end: tx.booking.end_on
        },
        opts: {
          max_attempts: 3,
          auth_context: auth_context
        }).rescue { |error_msg, data|

        new_data =
          if data[:error].present?
            # An error occurred, assume connection issue
            {reason: :connection_issue, listing_id: tx.listing_id}
          else
            case data[:status]
            when 409
              # Conflict or double bookings, assume double booking
              {reason: :double_booking, listing_id: tx.listing_id}
            else
              # Unknown. Return unchanged.
              data
            end
          end

        Result::Error.new(error_msg, new_data.merge(listing_id: tx.listing_id))
      }
    end

    def send_message(tx, message, sender_id)
      TxStore.add_message(community_id: tx.community_id,
                          transaction_id: tx.id,
                          message: message,
                          sender_id: sender_id)
    end

    def proc_status_response(proc_token)
      Result::Success.new(
        ProcessStatus.create_process_status({
                                              process_token: proc_token[:process_token],
                                              completed: proc_token[:op_completed],
                                              result: proc_token[:op_output]}))
    end

    def logger
      @logger ||= SharetribeLogger.new(:preauthorize_process)
    end

    def ensure_can_execute!(tx:, allowed_states:)
      tx_state = tx.current_state

      unless allowed_states.include?(tx_state.to_sym)
        raise TransactionService::Transaction::IllegalTransactionStateException.new(
               "Transaction was in illegal state, expected state: [#{allowed_states.join(',')}], actual state: #{tx_state}")
      end
    end
  end
end
