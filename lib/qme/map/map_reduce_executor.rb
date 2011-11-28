module QME

  module MapReduce

    # Computes the value of quality measures based on the current set of patient
    # records in the database
    class Executor

      include DatabaseAccess

      # Create a new Executor for a specific measure, effective date and patient population.
      # @param [String] measure_id the measure identifier
      # @param [String] sub_id the measure sub-identifier or null if the measure is single numerator
      # @param [Hash] parameter_values a hash that may contain the following keys: 'effective_date' the measurement period end date, 'test_id' an identifier for a specific set of patients
      def initialize(measure_id, sub_id, parameter_values)
        @measure_id = measure_id
        @sub_id = sub_id
        @parameter_values = parameter_values
        determine_connection_information
      end

      # Examines the patient_cache collection and generates a total of all groups
      # for the measure. The totals are placed in a document in the query_cache
      # collection.
      # @return [Hash] measure groups (like numerator) as keys, counts as values
      def count_records_in_measure_groups
        patient_cache = get_db.collection('patient_cache')
        query = {'value.measure_id' => @measure_id, 'value.sub_id' => @sub_id,
                 'value.effective_date' => @parameter_values['effective_date'],
                 'value.test_id' => @parameter_values['test_id']}
        
        query.merge!(filter_parameters)
        
        result = {:measure_id => @measure_id, :sub_id => @sub_id, 
                  :effective_date => @parameter_values['effective_date'],
                  :test_id => @parameter_values['test_id'], :filters => @parameter_values['filters']}
        
        aggregate = patient_cache.group({cond: query, 
                                           initial: {population: 0, denominator: 0, numerator: 0, antinumerator: 0,  exclusions: 0}, 
                                           reduce: "function(record,sums) { for (var key in sums) { sums[key] += (record['value'][key]) ? 1 : 0 } }"}).first
        
        aggregate ||= {population: 0, denominator: 0, numerator: 0, antinumerator: 0,  exclusions: 0}
        aggregate.each {|key, value| aggregate[key] = value.to_i}
        result.merge!(aggregate)
 
# need to time the old way agains the single query to verify that the single query is more performant        
#        %w(population denominator numerator antinumerator exclusions).each do |measure_group|
#          patient_cache.find(query.merge("value.#{measure_group}" => true)) do |cursor|
#            result[measure_group] = cursor.count
#          end
#        end

        result.merge!(execution_time: (Time.now.to_i - @parameter_values['start_time'].to_i)) if @parameter_values['start_time']

        get_db.collection("query_cache").save(result)
        result
      end

      # This method runs the MapReduce job for the measure which will create documents
      # in the patient_cache collection. These documents will state the measure groups
      # that the record belongs to, such as numerator, etc.
      def map_records_into_measure_groups
        qm = QualityMeasure.new(@measure_id, @sub_id)
        measure = Builder.new(get_db, qm.definition, @parameter_values)
        records = get_db.collection('records')
        records.map_reduce(measure.map_function, "function(key, values){return values;}",
                           :out => {:reduce => 'patient_cache'}, 
                           :finalize => measure.finalize_function,
                           :query => {:test_id => @parameter_values['test_id']})
      end
      
      def filter_parameters
        results = {}
        if(filters = @parameter_values['filters'])
          if (filters['providers'] && filters['providers'].size > 0)
            # TODO: NEED TO CHECK DATES FOR PROVIDER PERFORMANCE
            providers = filters['providers'].map {|provider_id| BSON::ObjectId(provider_id) if provider_id }
            results.merge!({'value.provider_performances.provider_id' => {'$in' => providers}})
          end
          if (filters['races'] && filters['races'].size > 0 && filters['ethnicities'] && filters['ethnicities'].size > 0)
            results.merge!({'value.race.code' => {'$in' => filters['races']}, 'value.ethnicity.code' => {'$in' => filters['ethnicities']}})
          end
          if (filters['genders'] && filters['genders'].size > 0)
            results.merge!({'value.gender' => {'$in' => filters['genders']}})
          end
        end
        results
      end
    end
  end
end
